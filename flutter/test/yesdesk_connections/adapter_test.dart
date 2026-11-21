import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/yesdesk/connections/catalog_codec.dart';
import 'package:flutter_hbb/yesdesk/connections/connection_launcher.dart';
import 'package:flutter_hbb/yesdesk/connections/connection_profile.dart';
import 'package:flutter_hbb/yesdesk/connections/connection_repository.dart';
import 'package:flutter_hbb/yesdesk/rdp/rdp_launcher.dart';
import 'package:flutter_hbb/yesdesk/rdp/rdp_profile_store.dart';
import 'package:flutter_hbb/yesdesk/ssh/pages/ssh_workspace.dart';
import 'package:flutter_hbb/yesdesk/ssh/storage/ssh_repository.dart';
import 'package:flutter_hbb/yesdesk/theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

Never unexpectedLaunch() => throw StateError('Unexpected transport selected');

ConnectionProfile profile(ConnectionType type, String host,
    {int? port, String username = '', Json settings = const {}}) {
  final id = const Uuid().v4();
  return ConnectionProfile(
    id: id,
    name: type.name,
    host: host,
    port: port,
    username: username,
    options:
        transportOptions(type, id, type.name, host, port, username, settings),
  );
}

void main() {
  late Directory root;
  late SshRepository ssh;
  late ConnectionRepository repository;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('yesdesk-adapter-test-');
    Future<Directory> directory(String name) async =>
        Directory('${root.path}/$name');
    ssh = SshRepository(() => directory('ssh'));
    repository = ConnectionRepository(
      ssh: ssh,
      rdp: RdpProfileStore(directory: () => directory('rdp')),
      nativePeers: () async => [],
      directory: () => directory('catalog'),
    );
  });
  tearDown(() => root.delete(recursive: true));

  test('invalid remote target is rejected before reaching the native adapter',
      () async {
    final invalid = ConnectionProfile(
      id: const Uuid().v4(),
      name: 'Invalid',
      host: 'https://example.com',
      options: const RemoteDesktopOptions(),
    );
    final launcher = ConnectionLauncher(
      openRemoteDesktop: (_, __) => unexpectedLaunch(),
      openSshTab: (_, __) => unexpectedLaunch(),
      rdp: RdpLauncher(),
    );
    await expectLater(launcher.launch(invalid), throwsFormatException);
  });

  test('the real MSTSC adapter reports unsupported platforms', () async {
    final rdp = profile(ConnectionType.rdp, 'windows.example');
    await repository.save(rdp);
    final launcher = ConnectionLauncher(
      openRemoteDesktop: (_, __) => unexpectedLaunch(),
      openSshTab: (_, __) => unexpectedLaunch(),
      rdp: RdpLauncher(),
    );
    final persisted = (await repository.load()).profiles[rdp.id]!;
    await expectLater(launcher.launch(persisted), throwsUnsupportedError);
  }, skip: Platform.isWindows);

  test(
      'the RDP adapter writes a credential-free Unicode file and follows a real process',
      () async {
    final rdp = profile(ConnectionType.rdp, 'windows.example',
        username: 'оператор', settings: {'gateway': 'gateway.example'});
    await repository.save(rdp);
    final persisted = (await repository.load()).profiles[rdp.id]!;
    final transport = (persisted.options as RdpOptions).transport;
    late IOSink release;
    final adapter = RdpLauncher(
      executable: () => '/bin/sh',
      temporaryRoot: root,
      start: (executable, args) async {
        final bytes = await File(args.single).readAsBytes();
        expect(bytes.take(2), [255, 254]);
        final units = [
          for (var offset = 2; offset < bytes.length; offset += 2)
            bytes[offset] | bytes[offset + 1] << 8,
        ];
        final contents = String.fromCharCodes(units);
        expect(contents, contains('full address:s:windows.example:3389'));
        expect(contents, contains('username:s:оператор'));
        expect(contents, contains('authentication level:i:1'));
        expect(contents, isNot(contains('password')));
        // The pipe keeps a real child alive until the test releases it.
        final process =
            await Process.start(executable, ['-c', 'read -r unused']);
        release = process.stdin;
        return process;
      },
    );
    final launcher = ConnectionLauncher(
      openRemoteDesktop: (_, __) => unexpectedLaunch(),
      openSshTab: (_, __) => unexpectedLaunch(),
      rdp: adapter,
    );
    final launched = await launcher.launch(persisted);
    expect(adapter.runningClients(transport.id), 1);
    release.writeln('exit');
    await release.close();
    expect(await launched.clientExit, 0);
    expect(adapter.runningClients(transport.id), 0);
    expect(
        await root.list().where((e) => e.path.contains('yesdesk-rdp-')).isEmpty,
        isTrue);
  }, skip: Platform.isWindows);

  final environment = Platform.environment;
  final fixturePort = int.tryParse(environment['YESDESK_SFTP_PORT'] ?? '');
  final key = environment['YESDESK_SFTP_KEY'];
  final fingerprint = environment['YESDESK_SFTP_FINGERPRINT'];
  for (final type in [ConnectionType.ssh, ConnectionType.sftp]) {
    testWidgets(
        '${type.name} catalog launch reaches real OpenSSH and existing workspace',
        (tester) async {
      final connection = profile(type, '127.0.0.1',
          port: fixturePort,
          username: 'sftp-test',
          settings: {'auth': 'privateKey'});
      final persisted = (await tester.runAsync(() async {
        await repository.save(connection);
        final result = (await repository.load()).profiles[connection.id]!;
        final transport = (result.options as SshConnectionOptions).transport;
        await ssh.remember(
            transport.endpoint, SshHostKey('ssh-ed25519', fingerprint!));
        return result;
      }))!;

      final workspace = GlobalKey<SshWorkspaceState>();
      final connected = Completer<String>();
      await tester.pumpWidget(MaterialApp(
          theme: ThemeData(extensions: const [YesDeskColors.light]),
          home: Scaffold(
              body: SshWorkspace(
            key: workspace,
            language: 'en',
            repository: ssh,
            onConnected: connected.complete,
          ))));
      final launcher = ConnectionLauncher(
        openRemoteDesktop: (_, __) => unexpectedLaunch(),
        openSshTab: (profile, filesOnly) async =>
            workspace.currentState!.openProfile(profile, filesOnly: filesOnly),
        rdp: RdpLauncher(),
      );
      await tester.runAsync(() => launcher.launch(persisted));
      final keyField = find.widgetWithText(TextField, 'Key file');
      await pumpUntil(tester, () => keyField.evaluate().isNotEmpty);
      await tester.enterText(keyField, key!);
      await tester.tap(find.text('Connect').last);
      await pumpUntil(tester, () => connected.isCompleted);
      final transport = (persisted.options as SshConnectionOptions).transport;
      expect(await connected.future, transport.id);
      expect(
          workspace.currentState!.activeCount(transport.id,
              filesOnly: type == ConnectionType.sftp),
          1);
      expect(
          workspace.currentState!.activeCount(transport.id,
              filesOnly: type != ConnectionType.sftp),
          0);
      if (type == ConnectionType.sftp) {
        await pumpUntil(
            tester, () => find.text('Remote path').evaluate().isNotEmpty);
      } else {
        expect(find.byTooltip('Show SFTP Explorer'), findsOneWidget);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    }, skip: fixturePort == null || key == null || fingerprint == null);
  }
}

Future<void> pumpUntil(WidgetTester tester, bool Function() condition) async {
  for (var retry = 0; retry < 100; retry++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 35)));
    await tester.pump(const Duration(milliseconds: 35));
    if (condition()) return;
  }
  fail('The existing workspace did not reach the expected state');
}
