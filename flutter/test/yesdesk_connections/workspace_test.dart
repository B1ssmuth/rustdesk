import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/yesdesk/connections/catalog_codec.dart';
import 'package:flutter_hbb/yesdesk/connections/connection_launcher.dart';
import 'package:flutter_hbb/yesdesk/connections/connection_profile.dart';
import 'package:flutter_hbb/yesdesk/connections/connection_repository.dart';
import 'package:flutter_hbb/yesdesk/connections/connections_workspace.dart';
import 'package:flutter_hbb/yesdesk/rdp/rdp_launcher.dart';
import 'package:flutter_hbb/yesdesk/rdp/rdp_profile_store.dart';
import 'package:flutter_hbb/yesdesk/ssh/storage/ssh_repository.dart';
import 'package:flutter_hbb/yesdesk/theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

void main() {
  late Directory root;
  late ConnectionRepository repository;
  late List<String> launches;
  late ConnectionLauncher launcher;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('yesdesk-workspace-test-');
    Future<Directory> directory(String name) async =>
        Directory('${root.path}/$name');
    repository = ConnectionRepository(
      ssh: SshRepository(() => directory('ssh')),
      rdp: RdpProfileStore(directory: () => directory('rdp')),
      nativePeers: () async => [],
      directory: () => directory('catalog'),
    );
    launches = [];
    launcher = ConnectionLauncher(
      openRemoteDesktop: (id, relay) async => launches.add('$id/$relay'),
      openSshTab: (profile, files) async =>
          launches.add('${profile.host}/$files'),
      rdp: RdpLauncher(),
    );
  });
  tearDown(() async {
    // Wait for queued catalog writes to release their Windows file handles.
    await repository.load();
    await root.delete(recursive: true);
  });

  Future<void> mount(WidgetTester tester,
      {String language = 'en',
      Brightness brightness = Brightness.light,
      double scale = 1}) async {
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(brightness: brightness, extensions: [
        brightness == Brightness.dark
            ? YesDeskColors.dark
            : YesDeskColors.light,
      ]),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: Scaffold(
          body: ConnectionsWorkspace(
        language: language,
        repository: repository,
        launcher: launcher,
        activity: (_) => ConnectionActivity.none,
      )),
    ));
    await pumpUntil(
        tester, () => find.byType(LinearProgressIndicator).evaluate().isEmpty);
    await tester.pumpAndSettle();
  }

  testWidgets('English create form, search, details and quick launch',
      (tester) async {
    await mount(tester);
    expect(find.text('No connections here'), findsOneWidget);
    await tester.tap(find.text('New connection'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Name'), 'Lab desktop');
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Host or ID'), '123 456 789');
    await tester.tap(find.text('Save'));
    await pumpUntil(tester,
        () => find.widgetWithText(Card, 'Lab desktop').evaluate().isNotEmpty);
    await tester.pumpAndSettle();
    expect(find.text('Lab desktop'), findsWidgets);
    await tester.tap(find.byTooltip('Close'));
    await tester.enterText(
        find.widgetWithText(TextField, 'Search connections'), 'missing');
    await tester.pumpAndSettle();
    expect(find.text('Lab desktop'), findsNothing);
    await tester.enterText(
        find.widgetWithText(TextField, 'Search connections'), 'Lab');
    await tester.pumpAndSettle();
    final name = find.text('Lab desktop');
    await tester.tap(name);
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(name);
    await pumpUntil(
        tester, () => find.byType(LinearProgressIndicator).evaluate().isEmpty);
    await tester.pumpAndSettle();
    expect(launches, ['123456789/false']);
  });

  testWidgets(
      'Russian dark view at 175% shows independent SSH and SFTP launch intent',
      (tester) async {
    await tester.runAsync(() async {
      for (final type in [ConnectionType.ssh, ConnectionType.sftp]) {
        final id = const Uuid().v4();
        await repository.save(ConnectionProfile(
          id: id,
          name: type.name,
          host: 'lab.example',
          username: 'ops',
          options: transportOptions(
              type, id, type.name, 'lab.example', 22, 'ops', {}),
        ));
      }
    });
    await mount(tester,
        language: 'ru-RU', brightness: Brightness.dark, scale: 1.75);
    expect(find.text('Поиск подключений'), findsOneWidget);
    expect(find.textContaining('Проводник SFTP'), findsOneWidget);
    await tester.tap(find.text('ssh'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Подключить'));
    await tester.tap(find.text('Подключить'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Закрыть'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('sftp'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Подключить'));
    await tester.tap(find.text('Подключить'));
    await tester.pumpAndSettle();
    expect(launches, ['lab.example/false', 'lab.example/true']);
    expect(tester.takeException(), isNull);
  });
}

Future<void> pumpUntil(WidgetTester tester, bool Function() condition) async {
  for (var retry = 0; retry < 100; retry++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump(const Duration(milliseconds: 30));
    if (condition()) return;
  }
  fail('The catalog did not finish updating');
}
