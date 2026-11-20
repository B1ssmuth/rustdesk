import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/yesdesk/ssh/controllers/ssh_tab.dart';
import 'package:flutter_hbb/yesdesk/ssh/models/ssh_profile.dart';
import 'package:flutter_hbb/yesdesk/ssh/pages/ssh_workspace.dart';
import 'package:flutter_hbb/yesdesk/ssh/services/ssh_transport.dart';
import 'package:flutter_hbb/yesdesk/ssh/storage/ssh_repository.dart';
import 'package:flutter_hbb/yesdesk/ssh/widgets/ssh_strings.dart';
import 'package:flutter_hbb/yesdesk/ssh/widgets/ssh_terminal_view.dart';
import 'package:flutter_hbb/yesdesk/theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';

class _ConnectedRun extends Fake implements SshRun {
  final sent = <String>[];

  @override
  bool get active => true;

  @override
  void write(String text) => sent.add(text);

  @override
  void resize() {}

  @override
  void cancel() {}
}

Widget _workspace(
        SshRepository repository, String language, Brightness brightness) =>
    MaterialApp(
      theme: ThemeData(brightness: brightness),
      home: Scaffold(
        body: YesDeskTheme(
          child: SshWorkspace(repository: repository, language: language),
        ),
      ),
    );

class _WidgetRepository extends SshRepository {
  final profiles = <String, SshProfile>{};

  @override
  Future<({List<SshProfile> profiles, List<String> groups})> load() async =>
      (profiles: profiles.values.toList(), groups: <String>[]);

  @override
  Future<String?> save(SshProfile profile, {bool clearSecret = false}) async {
    profiles[profile.id] = profile;
    return null;
  }
}

void main() {
  late _WidgetRepository repository;
  setUp(() => repository = _WidgetRepository());

  testWidgets('English light and Russian dark catalogs use the YES Desk theme',
      (tester) async {
    await repository.save(SshProfile(
      id: 'theme',
      name: 'Lab server',
      host: 'localhost',
      username: 'test',
    ));
    for (final (locale, brightness, title, search) in [
      ('en', Brightness.light, 'SSH Terminal', 'Search servers'),
      ('ru_RU', Brightness.dark, 'SSH-терминал', 'Поиск серверов'),
    ]) {
      await tester.pumpWidget(_workspace(repository, locale, brightness));
      await tester.pumpAndSettle();
      expect(find.text(title), findsOneWidget);
      expect(find.text(search), findsOneWidget);
      expect(find.text('Lab server'), findsOneWidget);
      final context = tester.element(find.byType(SshWorkspace));
      expect(Theme.of(context).brightness, brightness);
      expect(
          YesDeskColors.of(context).canvas,
          brightness == Brightness.light
              ? YesDeskColors.light.canvas
              : YesDeskColors.dark.canvas);
    }
  });

  testWidgets('create and edit a profile from catalog actions', (tester) async {
    await tester.pumpWidget(_workspace(repository, 'en', Brightness.light));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('New connection'));
    await tester.pumpAndSettle();
    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'Lab host');
    await tester.enterText(fields.at(1), '127.0.0.1');
    await tester.enterText(fields.at(3), 'test-user');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(find.text('Lab host'), findsOneWidget);
    await tester.tap(find.byTooltip('Connection actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, 'Edited lab');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(repository.profiles.values.single.name, 'Edited lab');
    expect(find.text('Edited lab'), findsOneWidget);
  });

  testWidgets(
      'drops OSC 52 and gates all multiline clipboard input on approval',
      (tester) async {
    final tab = SshTab(
        SshProfile(
          id: 'paste',
          name: 'Shell',
          host: 'localhost',
          username: 'test',
        ),
        repository);
    final run = _ConnectedRun();
    tab
      ..run = run
      ..phase = SshPhase.active;
    final clipboardWrites = <Object?>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboardWrites.add(call.arguments);
      }
      if (call.method == 'Clipboard.getData') return {'text': 'alpha\nbeta'};
      return null;
    });
    addTearDown(() =>
        messenger.setMockMethodCallHandler(SystemChannels.platform, null));

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: YesDeskTheme(
          child: SshTerminalView(tab: tab, labels: SshStrings('en')),
        ),
      ),
    ));
    final terminalView = tester.widget<TerminalView>(find.byType(TerminalView));
    expect(terminalView.theme, TerminalThemes.defaultTheme);
    tab.terminal.write('\x1b]52;c;Y2xpcGJvYXJk\x07');
    await tester.pump();
    expect(clipboardWrites, isEmpty);

    await tester.tap(find.byTooltip('Paste'));
    await tester.pumpAndSettle();
    expect(find.text('Paste multiple lines?'), findsOneWidget);
    expect(run.sent, isEmpty);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(run.sent, isEmpty);

    await tester.tap(find.byTooltip('Paste'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Paste'));
    await tester.pumpAndSettle();
    expect(run.sent.single.replaceAll('\r', '\n'), 'alpha\nbeta');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(run.sent.last, '\x03');

    await tester.pumpWidget(const SizedBox.shrink());
    tab.dispose();
  });
}
