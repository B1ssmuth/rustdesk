import 'dart:async';
import 'dart:io';

import 'package:flutter_hbb/yesdesk/ssh/models/ssh_profile.dart';
import 'package:flutter_hbb/yesdesk/ssh/services/ssh_transport.dart';
import 'package:flutter_hbb/yesdesk/ssh/storage/ssh_repository.dart';
import 'package:flutter_test/flutter_test.dart';

SshProfile testProfile(int port,
        {String host = '127.0.0.1', int timeout = 1}) =>
    SshProfile(
        id: 'test',
        name: 'Loopback',
        host: host,
        port: port,
        username: 'fixture',
        timeoutSeconds: timeout);

const testSize = (columns: 80, rows: 24, width: 0, height: 0);

SshPrompts promptsWithoutCredentials() => SshPrompts(
      verify: (_, __) async => throw StateError('Unexpected host verification'),
      password: (_) async => throw StateError('Unexpected credential prompt'),
      privateKey: (_) async => throw StateError('Unexpected key prompt'),
      challenge: (_, __) async => throw StateError('Unexpected challenge'),
    );

void main() {
  late Directory directory;
  late SshRepository repository;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('yesdesk-ssh-transport-');
    repository = SshRepository(() async => directory);
  });
  tearDown(() async => directory.delete(recursive: true));

  test('reports an unavailable localhost destination', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;
    await server.close();
    final phases = <SshPhase>[];
    final run = SshRun(
        // Windows can retry a refused TCP SYN before returning WSAECONNREFUSED.
        profile: testProfile(port, timeout: 8),
        trust: repository,
        prompts: promptsWithoutCredentials(),
        onPhase: phases.add,
        onText: (_) {},
        size: () => testSize);
    await run.start();
    expect(phases, [SshPhase.connecting, SshPhase.closing, SshPhase.failed]);
    expect(run.failure, SshFailure.unavailable);
  });

  for (final cancel in [false, true]) {
    test(
        cancel
            ? 'cancel closes the pending SSH socket'
            : 'handshake times out and releases the SSH socket', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final accepted = Completer<void>();
      final disconnected = Completer<void>();
      final listener = server.listen((socket) {
        addTearDown(socket.destroy);
        socket.listen((_) {}, onDone: disconnected.complete);
        accepted.complete();
      });
      addTearDown(listener.cancel);
      final phases = <SshPhase>[];
      final run = SshRun(
          profile: testProfile(server.port),
          trust: repository,
          prompts: promptsWithoutCredentials(),
          onPhase: phases.add,
          onText: (_) {},
          size: () => testSize);
      addTearDown(run.cancel);
      final started = run.start();
      await accepted.future.timeout(const Duration(seconds: 5));
      if (cancel) run.cancel();
      await started.timeout(const Duration(seconds: 5));
      await disconnected.future.timeout(const Duration(seconds: 5));
      expect(phases, [
        SshPhase.connecting,
        SshPhase.closing,
        cancel ? SshPhase.closed : SshPhase.failed
      ]);
      expect(run.failure, cancel ? isNull : SshFailure.timeout);
    });
  }
}
