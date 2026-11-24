import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/yesdesk/rdp/rdp_launcher.dart';
import 'package:flutter_hbb/yesdesk/rdp/rdp_profile.dart';
import 'package:flutter_hbb/yesdesk/rdp/rdp_profile_store.dart';
import 'package:flutter_hbb/yesdesk/rdp/rdp_workspace.dart';
import 'package:flutter_hbb/yesdesk/theme.dart';
import 'package:flutter_test/flutter_test.dart';

RdpProfile _profile({String name = 'Production', String gateway = ''}) =>
    RdpProfile(
      name: name,
      endpoint: RdpEndpoint.parse('srv.example.com', 3390)!,
      username: r'DOMAIN\пользователь',
      gateway: gateway,
      clipboard: true,
      fullscreen: true,
    );

class _MstscProcess implements Process {
  final exit = Completer<int>();

  @override
  Future<int> get exitCode => exit.future;

  @override
  Stream<List<int>> get stdout => const Stream.empty();

  @override
  Stream<List<int>> get stderr => const Stream.empty();

  @override
  Never noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('parses DNS, IPv4 and IPv6 with explicit ports', () {
    expect(RdpEndpoint.parse('Server.EXAMPLE', 3390)?.address,
        'server.example:3390');
    expect(RdpEndpoint.parse('127.0.0.1', 1)?.address, '127.0.0.1:1');
    expect(RdpEndpoint.parse('[2001:db8::1]', 65535)?.address,
        '[2001:db8::1]:65535');
    expect(RdpEndpoint.parse('::1', 3389)?.address, '[::1]:3389');
    for (final host in [
      '',
      'x /admin',
      'https://host',
      'host:3389',
      'x\r\nauthentication level:i:0',
      '999.1.1.1',
      'bad..host',
      '[host]',
      'fe80::1%3',
    ]) {
      expect(RdpEndpoint.parse(host, 3389), isNull, reason: host);
    }
    expect(RdpEndpoint.parse('valid', 0), isNull);
    expect(RdpEndpoint.parse('valid', 65536), isNull);
  });

  test('generated file pins certificate checking and opts into CredSSP', () {
    final direct = rdpConnectionFile(_profile());
    final viaGateway = rdpConnectionFile(_profile(gateway: 'gw.example.com'));
    for (final content in [direct, viaGateway]) {
      expect(content, contains('authentication level:i:1\r\n'));
      expect(content, contains('enablecredsspsupport:i:1\r\n'));
      expect(content, contains('autoreconnection enabled:i:1\r\n'));
      expect(content, contains('username:s:DOMAIN\\пользователь\r\n'));
      expect(content, contains('full address:s:srv.example.com:3390\r\n'));
      expect(content, contains('screen mode id:i:2\r\n'));
      expect(content, contains('smart sizing:i:1\r\n'));
      expect(content, contains('redirectclipboard:i:1\r\n'));
      expect(content, isNot(contains('password')));
    }
    expect(direct, contains('gatewayusagemethod:i:0\r\n'));
    expect(direct, isNot(contains('gatewayhostname')));
    expect(viaGateway, contains('gatewayhostname:s:gw.example.com\r\n'));
    expect(viaGateway, contains('gatewayusagemethod:i:1\r\n'));
    expect(viaGateway, contains('gatewayprofileusagemethod:i:1\r\n'));
    expect(viaGateway, contains('promptcredentialonce:i:0\r\n'));
  });

  test('profile data cannot inject security options or credentials', () {
    final original = _profile().toJson();
    final injected = {
      ...original,
      'password': 'not retained',
      'authentication level': 0,
      'enablecredsspsupport': 0,
    };
    final profile = RdpProfile.fromJson(injected);
    expect(profile.toJson(), original);
    expect(rdpConnectionFile(profile), isNot(contains('not retained')));
    for (final field in ['host', 'username', 'gateway']) {
      expect(
        () => RdpProfile.fromJson({
          ...original,
          field: 'valid\r\nauthentication level:i:0',
        }),
        throwsFormatException,
      );
    }
    expect(
      () => RdpProfile.fromJson({...original, 'width': 0}),
      throwsFormatException,
    );
  });

  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('rdp-test-');
  });
  tearDown(() => directory.delete(recursive: true));

  test('profile writes serialize and edits keep their original identity',
      () async {
    final store = RdpProfileStore(directory: () async => directory);
    final first = _profile();
    final second = _profile(name: 'Testing');
    await Future.wait([store.save(first), store.save(second)]);
    final reader = RdpProfileStore(directory: () async => directory);
    expect((await reader.load()).map((p) => p.name), ['Production', 'Testing']);
    await store.save(RdpProfile.fromJson({...first.toJson(), 'name': 'Live'}));
    expect((await reader.load()).map((p) => p.name), ['Live', 'Testing']);
    await store.delete(first.id);
    expect((await reader.load()).single.id, second.id);
  });

  test('independent launches use Unicode files and clean up on process exit',
      () async {
    final files = <File>[];
    final processes = <_MstscProcess>[];
    const exe = r'C:\Windows\System32\mstsc.exe';
    final launcher = RdpLauncher(
      executable: () => exe,
      temporaryRoot: directory,
      start: (executable, args) async {
        expect(executable, exe);
        expect(args, hasLength(1));
        final file = File(args.single);
        final bytes = await file.readAsBytes();
        expect(bytes.take(2), [0xff, 0xfe]);
        final decoded = String.fromCharCodes([
          for (var i = 2; i < bytes.length; i += 2)
            bytes[i] | (bytes[i + 1] << 8),
        ]);
        expect(decoded, contains(r'DOMAIN\пользователь'));
        expect(decoded, contains('authentication level:i:1'));
        files.add(file);
        final process = _MstscProcess();
        processes.add(process);
        return process;
      },
    );
    final first = await launcher.launch(_profile());
    final second = await launcher.launch(_profile(gateway: 'gw.example.com'));
    expect(files.first.path, isNot(files.last.path));
    processes[0].exit.complete(5);
    expect(await first.exitCode, 5);
    expect(await files.first.exists(), isFalse);
    expect(await files.last.exists(), isTrue);
    processes[1].exit.complete(0);
    expect(await second.exitCode, 0);
    expect(await directory.list().toList(), isEmpty);
  });

  test('launch failure cleans the temporary connection file', () async {
    final launcher = RdpLauncher(
      executable: () => 'mstsc.exe',
      temporaryRoot: directory,
      start: (_, __) async => throw const ProcessException('mstsc.exe', []),
    );
    await expectLater(
        launcher.launch(_profile()), throwsA(isA<ProcessException>()));
    expect(await directory.list().toList(), isEmpty);
  });

  testWidgets('creates a profile and reports launch and process failures',
      (tester) async {
    final store = RdpProfileStore(directory: () async => directory);
    final process = _MstscProcess();
    var attempts = 0;
    final launcher = RdpLauncher(
      executable: () => 'mstsc.exe',
      temporaryRoot: directory,
      start: (_, __) async {
        if (++attempts == 1) throw const ProcessException('mstsc.exe', []);
        return process;
      },
    );
    await tester.pumpWidget(MaterialApp(
      home: YesDeskTheme(
        child: Scaffold(
          body: RdpWorkspace(language: 'en', store: store, launcher: launcher),
        ),
      ),
    ));

    Future<void> waitFor(Finder finder) async {
      for (var i = 0; i < 100; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 5)));
        await tester.pump(const Duration(milliseconds: 20));
        if (finder.evaluate().isNotEmpty) return;
      }
      expect(finder, findsOneWidget);
    }

    await waitFor(
        find.text('Add a profile for a Windows server or workstation.'));
    await tester.tap(find.text('New profile'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pump();
    expect(find.text('Enter a name'), findsOneWidget);
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Profile name'), 'Production');
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Host or IP address'),
        'srv.example.com');
    await tester.tap(find.text('Save'));
    await waitFor(find.text('srv.example.com:3389'));
    expect(find.text('Production'), findsOneWidget);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Connect'));
    await waitFor(find.text('Could not start the Windows RDP client.'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Connect'));
    await waitFor(find.text('Opened Windows Remote Desktop Connection.'));
    expect(attempts, 2);
    process.exit.complete(9);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await waitFor(find.textContaining(
        'verify the trusted chain and the DNS name for srv.example.com'));
  });
}
