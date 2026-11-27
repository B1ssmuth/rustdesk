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

  testWidgets(
      'unified workspace loads managed devices after login and clears them at expiry',
      (tester) async {
    final authenticated = ValueNotifier(false);
    final queries = <Map<String, String>?>[];
    var discoveryRequested = false;
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(extensions: [YesDeskColors.light]),
      home: Scaffold(
          body: ValueListenableBuilder<bool>(
        valueListenable: authenticated,
        builder: (_, enabled, __) => ConnectionsWorkspace(
          language: 'en',
          repository: repository,
          launcher: launcher,
          activity: (_) => ConnectionActivity.none,
          unified: true,
          discover: () => discoveryRequested = true,
          allowProfessional: enabled,
          managementAvailable: enabled,
          managementApi: (path, {query, method = 'GET', body}) async {
            expect(path, '/v2/workspace');
            queries.add(query);
            return {
              'rows': [
                {
                  'hostname': 'Pilot AD workstation',
                  'ad_id': 'ad-1',
                  'device_id': null,
                  'hotel': 'Pilot Hotel',
                  'agent_registered': false
                }
              ],
              'hotels': ['Pilot Hotel'],
              'has_next': false,
              'sync': null,
            };
          },
        ),
      )),
    ));
    await pumpUntil(
        tester, () => find.byType(LinearProgressIndicator).evaluate().isEmpty);
    await tester.pumpAndSettle();
    expect(queries, isEmpty);
    expect(find.text('Corporate devices'), findsNothing);
    await tester.tap(find.byTooltip('Discover LAN devices'));
    expect(discoveryRequested, isTrue);
    authenticated.value = true;
    await tester.pumpAndSettle();
    expect(queries, isNotEmpty);
    expect(find.text('Pilot AD workstation'), findsOneWidget);
    expect(find.textContaining('No agent'), findsOneWidget);
    expect(queries.last?['hotel'], isNull);
    await tester.tap(find.widgetWithText(ListTile, 'Pilot Hotel').first);
    await tester.pumpAndSettle();
    expect(queries.last?['hotel'], 'Pilot Hotel');
    await tester.enterText(find.byType(TextField).first, '192.0.2.8');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(queries.last?['q'], '192.0.2.8');
    expect(queries.last?['hotel'], 'Pilot Hotel');
    expect(queries.last?['status'], 'all');
    authenticated.value = false;
    await tester.pumpAndSettle();
    expect(find.text('Pilot AD workstation'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    authenticated.dispose();
  });

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

    // Drain connection history writes while the widget's test clock can still run.
    await tester.pumpWidget(const SizedBox.shrink());
    var catalogIdle = false;
    repository.load().then((_) => catalogIdle = true);
    await pumpUntil(tester, () => catalogIdle);
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
