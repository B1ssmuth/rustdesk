import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../models/ssh_profile.dart';
import '../storage/ssh_repository.dart';

enum SshPhase {
  idle,
  connecting,
  verifyingHost,
  authenticating,
  active,
  closing,
  closed,
  failed
}

enum SshFailure {
  timeout,
  unavailable,
  rejected,
  changedKey,
  authentication,
  privateKey,
  disconnected,
  protocol,
  storage,
}

typedef SshSize = ({int columns, int rows, int width, int height});
typedef SshKeyInput = ({String path, String? passphrase});

class SshPrompts {
  const SshPrompts({
    required this.verify,
    required this.password,
    required this.privateKey,
    required this.challenge,
  });

  final Future<bool> Function(SshHostKey key, Future<void> ended) verify;
  final Future<String?> Function(Future<void> ended) password;
  final Future<SshKeyInput?> Function(Future<void> ended) privateKey;
  final Future<List<String>?> Function(
      SSHUserInfoRequest request, Future<void> ended) challenge;
}

/// Owns one TCP connection, SSH client and PTY. A reconnect creates a new run.
class SshRun {
  SshRun({
    required this.profile,
    required this.trust,
    required this.prompts,
    required this.onPhase,
    required this.onText,
    required this.size,
    this.terminal = true,
  });

  final bool terminal;
  final SshProfile profile;
  final SshHostTrust trust;
  final SshPrompts prompts;
  final void Function(SshPhase) onPhase;
  final void Function(String) onText;
  final SshSize Function() size;

  final _ended = Completer<void>();
  ConnectionTask<Socket>? _dial;
  SSHSocket? _socket;
  SSHClient? _client;
  SSHSession? _shell;
  final _readers = <StreamSubscription<String>>[];
  Timer? _stageTimer;
  Timer? _resizeTimer;
  Timer? _outputTimer;
  final _output = StringBuffer();
  bool _started = false;
  SshFailure? failure;
  SshHostKey? expectedKey;
  SshHostKey? receivedKey;
  bool get ended => _ended.isCompleted;
  bool _authenticated = false;
  bool wasActive = false;
  bool get active => !ended && _authenticated && (!terminal || _shell != null);
  Future<void> get done => _ended.future;

  Future<SftpClient> openSftp() async {
    final client = _client;
    if (!active || client == null) throw const _SshCancelled();
    // A late channel open must still be disposed after the caller times out.
    var abandoned = false;
    final opening = client.sftp(timeout: _timeout).then((sftp) {
      if (ended || abandoned) {
        sftp.close().ignore();
        throw const _SshCancelled();
      }
      return sftp;
    });
    SftpClient? sftp;
    try {
      final opened = await _untilEnded<SftpClient>(opening, _timeout);
      sftp = opened;
      await _untilEnded(opened.handshake, _timeout);
      return opened;
    } catch (_) {
      abandoned = true;
      sftp?.close().ignore();
      rethrow;
    }
  }

  Duration get _timeout => Duration(seconds: profile.timeoutSeconds);
  static const _promptTimeout = Duration(minutes: 2);

  Future<T> _untilEnded<T>(Future<T> operation, [Duration? timeout]) {
    final result = Future.any([
      operation,
      _ended.future.then<T>((_) => throw const _SshCancelled()),
    ]);
    return timeout == null ? result : result.timeout(timeout);
  }

  void _startStageTimer() {
    _stageTimer?.cancel();
    if (!ended) {
      _stageTimer = Timer(_timeout, () => _finish(SshFailure.timeout));
    }
  }

  Future<T?> _ask<T>(Future<T?> Function(Future<void>) show) async {
    _stageTimer?.cancel();
    try {
      final response = await _untilEnded(show(_ended.future), _promptTimeout);
      if (response == null) cancel();
      return ended ? null : response;
    } on TimeoutException {
      _finish(SshFailure.timeout);
      return null;
    } on _SshCancelled {
      return null;
    } catch (_) {
      _finish(SshFailure.authentication);
      return null;
    } finally {
      _startStageTimer();
    }
  }

  Future<void> start() async {
    if (_started || ended) return;
    _started = true;
    onPhase(SshPhase.connecting);
    try {
      final identities = await _loadIdentities();
      final socket = await _untilEnded(_openSocket(), _timeout);
      _socket = socket;

      _startStageTimer();
      var passwordRequested = false;
      bool verified = false;
      final client = _client = SSHClient(
        socket,
        username: profile.username,
        algorithms: const SSHAlgorithms(
          cipher: [
            SSHCipherType.aes256gcm,
            SSHCipherType.aes128gcm,
            SSHCipherType.aes256ctr,
            SSHCipherType.aes128ctr,
          ],
          mac: [
            SSHMacType.hmacSha256Etm,
            SSHMacType.hmacSha512Etm,
            SSHMacType.hmacSha256,
            SSHMacType.hmacSha512,
          ],
        ),
        identities: identities,
        onVerifyHostKey: (algorithm, fingerprint) async {
          _stageTimer?.cancel();
          try {
            verified =
                await _verify(SshHostKey(algorithm, utf8.decode(fingerprint)));
            if (verified && !ended) {
              onPhase(SshPhase.authenticating);
              _startStageTimer();
            }
            return verified && !ended;
          } on TimeoutException {
            failure = SshFailure.timeout;
          } on _SshCancelled {
            return false;
          } catch (_) {
            failure = SshFailure.storage;
          }
          return false;
        },
        onPasswordRequest: profile.auth == SshAuth.password
            ? () async {
                if (!verified || ended || passwordRequested) return null;
                passwordRequested = true;
                return _ask(prompts.password);
              }
            : null,
        onUserInfoRequest: profile.auth == SshAuth.keyboardInteractive
            ? (request) async {
                if (!verified || ended) return null;
                if (request.prompts.isEmpty) return <String>[];
                return _ask((ended) => prompts.challenge(request, ended));
              }
            : null,
      );

      unawaited(client.done.then<void>((_) {
        if (!ended) {
          _finish(active ? SshFailure.disconnected : SshFailure.protocol);
        }
      }, onError: (Object error, StackTrace _) {
        if (!ended) _finish(failure ?? _classify(error));
      }));

      // Authentication completes only after the host key callback succeeds.
      await _untilEnded(client.authenticated);
      _authenticated = true;
      _stageTimer?.cancel();
      if (!terminal) {
        wasActive = true;
        onPhase(SshPhase.active);
        return;
      }
      final initial = size();
      final shell = await _untilEnded(
          client.shell(
              pty: SSHPtyConfig(
            type: 'xterm-256color',
            width: initial.columns,
            height: initial.rows,
            pixelWidth: initial.width,
            pixelHeight: initial.height,
          )),
          _timeout);
      _shell = shell;
      var streamsRemaining = 2;
      for (final stream in [shell.stdout, shell.stderr]) {
        _readers.add(const Utf8Decoder(allowMalformed: true)
            .bind(stream)
            .listen(_queueOutput, onError: (Object _) {
          if (!ended) _finish(SshFailure.disconnected);
        }, onDone: () {
          if (--streamsRemaining == 0 && !ended) _finish();
        }));
      }
      resize();
      wasActive = true;
      onPhase(SshPhase.active);
    } on _SshCancelled {
      return;
    } catch (error) {
      if (!ended) _finish(failure ?? _classify(error));
    }
  }

  Future<List<SSHKeyPair>?> _loadIdentities() async {
    if (profile.auth != SshAuth.privateKey) return null;
    final input =
        await _untilEnded(prompts.privateKey(_ended.future), _promptTimeout);
    if (input == null) {
      cancel();
      throw const _SshCancelled();
    }
    try {
      return await _readKey(input);
    } on TimeoutException {
      rethrow;
    } on _SshCancelled {
      rethrow;
    } catch (_) {
      failure = SshFailure.privateKey;
      rethrow;
    }
  }

  Future<List<SSHKeyPair>> _readKey(SshKeyInput input) async {
    final reply = ReceivePort();
    Isolate? worker;
    var finished = false;
    try {
      final start = Isolate.spawn(
        _parseKey,
        (input, reply.sendPort),
        onExit: reply.sendPort,
        onError: reply.sendPort,
      ).then((isolate) {
        worker = isolate;
        if (finished) isolate.kill(priority: Isolate.immediate);
        return reply.first;
      });
      final result = await _untilEnded(start, _timeout);
      if (result is List<SSHKeyPair>) return result;
      throw const FormatException('Could not parse the SSH key');
    } finally {
      finished = true;
      worker?.kill(priority: Isolate.immediate);
      reply.close();
    }
  }

  static Future<void> _parseKey((SshKeyInput, SendPort) request) async {
    final (input, reply) = request;
    try {
      final file = await File(input.path).open();
      late final List<SSHKeyPair> identities;
      try {
        final length = await file.length();
        if (length < 1 || length > 256 * 1024) {
          throw const FormatException('Invalid SSH key size');
        }
        identities = SSHKeyPair.fromPem(
          utf8.decode(await file.read(length)),
          input.passphrase,
        );
      } finally {
        await file.close();
      }
      Isolate.exit(reply, identities);
    } catch (_) {
      Isolate.exit(reply);
    }
  }

  Future<SSHSocket> _openSocket() async {
    final task = await Socket.startConnect(
      SshProfile.normalizeHost(profile.host),
      profile.port,
    );
    _dial = task;
    if (ended) task.cancel();
    try {
      final socket = _TcpSshSocket(await task.socket);
      if (ended) {
        socket.destroy();
        throw const _SshCancelled();
      }
      // Publish ownership before the await in start can lose a cancellation race.
      return _socket = socket;
    } finally {
      _dial = null;
    }
  }

  Future<bool> _verify(SshHostKey candidate) async {
    final stored = await _untilEnded(trust.lookup(profile.endpoint), _timeout);
    if (stored != null) return _compare(stored, candidate);
    if (ended) return false;
    onPhase(SshPhase.verifyingHost);
    if (!await _untilEnded(
        prompts.verify(candidate, _ended.future), _promptTimeout)) {
      failure = SshFailure.rejected;
      return false;
    }
    if (ended) return false;
    final conflict = await _untilEnded(
        trust.remember(profile.endpoint, candidate), _timeout);
    return conflict == null || _compare(conflict, candidate);
  }

  bool _compare(SshHostKey stored, SshHostKey candidate) {
    if (stored.matches(candidate)) return true;
    expectedKey = stored;
    receivedKey = candidate;
    failure = SshFailure.changedKey;
    return false;
  }

  void write(String text) {
    if (active) _shell?.write(Uint8List.fromList(utf8.encode(text)));
  }

  void resize() {
    if (!active || _shell == null) return;
    _resizeTimer?.cancel();
    _resizeTimer = Timer(const Duration(milliseconds: 60), () {
      if (!active || _shell == null) return;
      final current = size();
      _shell!.resizeTerminal(
          current.columns, current.rows, current.width, current.height);
    });
  }

  void _queueOutput(String text) {
    if (ended) return;
    _output.write(text);
    _outputTimer ??= Timer(const Duration(milliseconds: 8), () {
      _outputTimer = null;
      _flushOutput();
      for (final reader in _readers) {
        if (reader.isPaused) reader.resume();
      }
    });
    if (_output.length >= 32 * 1024) {
      for (final reader in _readers) {
        if (!reader.isPaused) reader.pause();
      }
    }
  }

  void _flushOutput() {
    if (_output.isEmpty) return;
    final text = _output.toString();
    _output.clear();
    onText(text);
  }

  SshFailure _classify(Object error) => switch (error) {
        TimeoutException() => SshFailure.timeout,
        SocketException() => SshFailure.unavailable,
        SSHAuthFailError() => SshFailure.authentication,
        SSHHostkeyError() => SshFailure.protocol,
        _ when active => SshFailure.disconnected,
        _ => SshFailure.protocol,
      };

  void cancel() => _finish();

  void _finish([SshFailure? error]) {
    if (ended) return;
    _ended.complete();
    onPhase(SshPhase.closing);
    failure = error;
    _stageTimer?.cancel();
    _resizeTimer?.cancel();
    _outputTimer?.cancel();
    _flushOutput();
    for (final reader in _readers) {
      unawaited(reader.cancel());
    }
    _readers.clear();
    _dial?.cancel();
    _shell?.close();
    final client = _client;
    if (client != null) {
      unawaited(client
          .close()
          .then<void>((_) {}, onError: (Object _, StackTrace __) {}));
    }
    _socket?.destroy();
    _shell = null;
    _client = null;
    _socket = null;
    onPhase(error == null ? SshPhase.closed : SshPhase.failed);
  }
}

class _SshCancelled implements Exception {
  const _SshCancelled();
}

class _TcpSshSocket extends SSHSocket {
  _TcpSshSocket(this.socket);
  final Socket socket;

  @override
  Stream<Uint8List> get stream => socket;
  @override
  StreamSink<List<int>> get sink => socket;
  @override
  Future<void> get done => socket.done;
  @override
  Future<void> close() async => socket.close();
  @override
  void destroy() => socket.destroy();
  @override
  Future<void> flush() => socket.flush();
}
