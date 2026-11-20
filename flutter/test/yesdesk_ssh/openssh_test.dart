import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_hbb/yesdesk/ssh/models/ssh_profile.dart';
import 'package:flutter_hbb/yesdesk/ssh/services/ssh_transport.dart';
import 'package:flutter_hbb/yesdesk/ssh/storage/ssh_repository.dart';
import 'package:flutter_test/flutter_test.dart';

final _environment = Platform.environment;
final _port = int.tryParse(_environment['YESDESK_TEST_PORT'] ?? '');
final _otherPort = int.tryParse(_environment['YESDESK_TEST_OTHER_PORT'] ?? '');
final _password = _environment['YESDESK_TEST_PASSWORD'] ?? '';
final _keyPath = _environment['YESDESK_TEST_KEY'] ?? '';
final _passphrase = _environment['YESDESK_TEST_KEY_PASSPHRASE'];
final _handshakeOnly = _environment['YESDESK_TEST_HANDSHAKE_ONLY'] == '1';

class _Session {
  _Session(
    SshRepository repository,
    SshAuth auth, {
    int? port,
    String host = '127.0.0.1',
    bool accept = true,
    String? password,
    bool wrongPassphrase = false,
    Future<bool> Function(Future<void>)? verify,
  }) {
    run = SshRun(
      profile: SshProfile(
        id: 'fixture',
        name: 'Fixture',
        host: host,
        port: port ?? _port!,
        username: _environment['YESDESK_TEST_USER']!,
        auth: auth,
      ),
      trust: repository,
      prompts: SshPrompts(
        verify: (key, ended) async {
          keys.add(key);
          return verify == null ? accept : await verify(ended);
        },
        password: (_) async {
          authenticationRequests++;
          return password ?? _password;
        },
        privateKey: (_) async => (
          path: _keyPath,
          passphrase: wrongPassphrase ? 'wrong' : _passphrase,
        ),
        challenge: (request, _) async {
          authenticationRequests++;
          return request.prompts
              .map((SSHUserInfoPrompt _) => _password)
              .toList();
        },
      ),
      onPhase: (phase) {
        phases.add(phase);
        if (phase == SshPhase.closed || phase == SshPhase.failed)
          ended.complete();
      },
      onText: output.write,
      size: () => size,
    );
  }

  late final SshRun run;
  final output = StringBuffer();
  final keys = <SshHostKey>[];
  final phases = <SshPhase>[];
  final ended = Completer<void>();
  int authenticationRequests = 0;
  SshSize size = (columns: 80, rows: 24, width: 0, height: 0);

  Future<void> waitFor(String text) async {
    final stopwatch = Stopwatch()..start();
    while (!output.toString().contains(text)) {
      if (run.ended || stopwatch.elapsed > const Duration(seconds: 8)) {
        fail('Did not receive the expected terminal marker');
      }
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  }

  Future<void> start() async {
    addTearDown(run.cancel);
    await run.start().timeout(const Duration(seconds: 20));
  }
}

void main() {
  late Directory directory;
  late SshRepository repository;

  group('Isolated OpenSSH',
      skip: _port == null ? 'Use scripts/test-yesdesk-ssh-openssh.sh' : false,
      () {
    setUp(() async {
      directory = await Directory.systemTemp.createTemp('yesdesk-openssh-');
      repository = SshRepository(() async => directory);
    });
    tearDown(() async => directory.delete(recursive: true));

    test(
        'rejects an unknown key before asking for credentials and shows OpenSSH fingerprint',
        () async {
      final session = _Session(repository, SshAuth.password, accept: false);
      await session.start();
      expect(session.run.failure, SshFailure.rejected);
      expect(session.authenticationRequests, 0);
      expect(session.phases.contains(SshPhase.authenticating), isFalse);
      expect(session.keys.single.algorithm, 'ssh-ed25519');
      expect(session.keys.single.fingerprint,
          _environment['YESDESK_TEST_HOST_FINGERPRINT']);
      expect(await repository.lookup(session.run.profile.endpoint), isNull);
    });

    test('blocks a substituted host key before authentication', () async {
      final original = _Session(repository, SshAuth.password, accept: false);
      await original.start();
      final changed = _Session(repository, SshAuth.password, port: _otherPort);
      final endpoint = changed.run.profile.endpoint;
      await repository.remember(endpoint, original.keys.single);
      await changed.start();
      expect(changed.run.failure, SshFailure.changedKey);
      expect(changed.authenticationRequests, 0);
      expect(changed.keys, isEmpty);
      expect(changed.run.expectedKey!.matches(original.keys.single), isTrue);
      expect(changed.run.receivedKey!.matches(original.keys.single), isFalse);
      expect((await repository.lookup(endpoint))!.matches(original.keys.single),
          isTrue);
    });

    test('cancel dismisses pending trust and sends no credentials', () async {
      final promptOpened = Completer<void>();
      final promptDismissed = Completer<void>();
      final session =
          _Session(repository, SshAuth.password, verify: (ended) async {
        promptOpened.complete();
        await ended;
        promptDismissed.complete();
        return true;
      });
      final started = session.start();
      await promptOpened.future.timeout(const Duration(seconds: 8));
      session.run.cancel();
      await started;
      await promptDismissed.future.timeout(const Duration(seconds: 2));
      expect(session.run.failure, isNull);
      expect(session.phases.last, SshPhase.closed);
      expect(session.authenticationRequests, 0);
      expect(await repository.lookup(session.run.profile.endpoint), isNull);
    });

    test('rejects a wrong private-key passphrase', () async {
      final session =
          _Session(repository, SshAuth.privateKey, wrongPassphrase: true);
      await session.start();
      expect(session.run.failure, SshFailure.privateKey);
      expect(session.keys, isEmpty);
    });

    test(
        'encrypted key, DNS and independent shells with UTF-8, PTY resize and input',
        () async {
      final first = _Session(repository, SshAuth.privateKey, host: 'localhost');
      final second =
          _Session(repository, SshAuth.privateKey, host: 'localhost');
      await first.start();
      await second.start();
      expect(first.run.active, isTrue,
          reason: '${first.run.failure} ${first.phases}');
      expect(second.run.active, isTrue,
          reason: '${second.run.failure} ${second.phases}');
      expect(first.keys, hasLength(1));
      expect(second.keys, isEmpty);
      expect(
          first.phases,
          containsAllInOrder([
            SshPhase.connecting,
            SshPhase.verifyingHost,
            SshPhase.authenticating,
            SshPhase.active,
          ]));
      first.size = (columns: 101, rows: 37, width: 0, height: 0);
      first.run.resize();
      await Future<void>.delayed(const Duration(milliseconds: 140));
      // Split a multibyte scalar across separate writes from the real shell.
      first.run.write(
          r'''printf '\320'; sleep .15; printf '\226-PTY\n'; stty size; printf '\nTERM=%s\n' "$TERM"''' +
              '\n');
      second.run.write("printf '\\nsecond-%s\\n' 'session'\n");
      await first.waitFor('Ж-PTY');
      await first.waitFor('37 101');
      await first.waitFor('TERM=xterm-256color');
      await second.waitFor('second-session');
      expect(first.output.toString(), isNot(contains('second-session')));
      expect(second.output.toString(), isNot(contains('Ж-PTY')));

      first.run.write("exit\n");
      await first.ended.future.timeout(const Duration(seconds: 8));
      expect(first.run.active, isFalse);
      expect(second.run.active, isTrue,
          reason: '${second.run.failure} ${second.phases}');
      second.run.cancel();
      await second.ended.future.timeout(const Duration(seconds: 2));
      expect(second.phases.last, SshPhase.closed);
    }, skip: _handshakeOnly);

    test('detects a dropped TCP connection to an established OpenSSH shell',
        () async {
      final proxy = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(proxy.close);
      Socket? incoming, outgoing;
      final relay = proxy.listen((socket) async {
        incoming = socket;
        final upstream = outgoing = await Socket.connect('127.0.0.1', _port!);
        socket.listen(upstream.add, onError: (_) {}, onDone: upstream.destroy);
        upstream.listen(socket.add, onError: (_) {}, onDone: socket.destroy);
      });
      addTearDown(relay.cancel);
      addTearDown(() {
        incoming?.destroy();
        outgoing?.destroy();
      });
      final session =
          _Session(repository, SshAuth.privateKey, port: proxy.port);
      await session.start();
      expect(session.run.active, isTrue);
      incoming!.destroy();
      outgoing!.destroy();
      await session.ended.future.timeout(const Duration(seconds: 8));
      expect(session.run.failure, SshFailure.disconnected);
    }, skip: _handshakeOnly);

    test(
        'password authentication and real shell output leave no secrets in logs or metadata',
        () async {
      final session = _Session(repository, SshAuth.password);
      final logged = <String>[];
      await runZoned(() async {
        await session.start();
        expect(session.run.active, isTrue);
        session.run.write("printf '\\noutput-%s\\n' 'no-log'\n");
        await session.waitFor('output-no-log');
      },
          zoneSpecification: ZoneSpecification(
              print: (_, __, ___, message) => logged.add(message)));
      expect(session.authenticationRequests, 1);
      expect(logged, isEmpty);
      final knownHosts =
          await File('${directory.path}/known-hosts.json').readAsString();
      expect(knownHosts, isNot(contains(_password)));
      expect(knownHosts, isNot(contains('output-no-log')));
    }, skip: _password.isEmpty);

    test('reports invalid password without repeatedly submitting it', () async {
      final session = _Session(repository, SshAuth.password,
          password: 'invalid-test-credential');
      await session.start();
      expect(session.run.failure, SshFailure.authentication);
      expect(session.authenticationRequests, 1);
    }, skip: _password.isEmpty);

    test('answers a keyboard-interactive challenge after host confirmation',
        () async {
      final session = _Session(repository, SshAuth.keyboardInteractive);
      await session.start();
      expect(session.run.active, isTrue);
      expect(session.authenticationRequests, greaterThan(0));
      expect(
          session.phases,
          containsAllInOrder(
              [SshPhase.verifyingHost, SshPhase.authenticating]));
    }, skip: _password.isEmpty);
  });
}
