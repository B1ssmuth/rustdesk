import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/yesdesk/ssh/models/ssh_profile.dart';
import 'package:flutter_hbb/yesdesk/ssh/services/ssh_transport.dart';
import 'package:flutter_hbb/yesdesk/ssh/sftp/sftp_explorer.dart';
import 'package:flutter_hbb/yesdesk/ssh/widgets/ssh_strings.dart';
import 'package:flutter_hbb/yesdesk/theme.dart';
import 'package:flutter_test/flutter_test.dart';

class _DirectoryClient extends Fake implements SftpClient {
  final calls = <String>[];
  bool closed = false;

  @override
  Future<String> absolute(String path) async => path == '.' ? '/home' : path;

  @override
  Future<List<SftpName>> listdir(String path) async {
    calls.add(path);
    return [
      if (path == '/home')
        SftpName(
            filename: 'каталог',
            longname: '',
            attr: SftpFileAttrs(mode: const SftpFileMode.value(0x4000))),
      SftpName(
          filename: 'Файл.txt',
          longname: '',
          attr:
              SftpFileAttrs(mode: const SftpFileMode.value(0x8000), size: 12)),
    ];
  }

  @override
  Future<void> close() async => closed = true;
}

class _Run extends Fake implements SshRun {
  final client = _DirectoryClient();
  final end = Completer<void>();

  @override
  Future<void> get done => end.future;

  @override
  bool get ended => end.isCompleted;

  @override
  final profile = SshProfile(
      id: 'fixture', name: 'Fixture', host: 'localhost', username: 'test');

  @override
  Future<SftpClient> openSftp() async => client;
}

void main() {
  testWidgets('explorer navigates and closes its channel without ending SSH',
      (tester) async {
    final run = _Run();
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: YesDeskTheme(
          child: SftpExplorer(
              run: run,
              labels: SshStrings('ru'),
              twoPanes: true,
              visible: true),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Локальная папка'), findsOneWidget);
    expect(find.text('Файл.txt'), findsOneWidget);
    expect(find.textContaining('12 Б'), findsOneWidget);
    await tester.tap(find.text('каталог'));
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(find.text('каталог'));
    await tester.pumpAndSettle();
    expect(run.client.calls, ['/home', '/home/каталог']);
    await tester.tap(find.byType(Checkbox));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.f5);
    await tester.pumpAndSettle();
    expect(run.client.calls.last, '/home/каталог');
    expect(run.client.calls.length, 3);
    await tester.tap(find.byTooltip('Закрыть канал SFTP'));
    await tester.pumpAndSettle();
    expect(run.client.closed, isTrue);
    expect(run.ended, isFalse);
    expect(find.text('Открыть SFTP'), findsOneWidget);
  });
}
