import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common/formatter/id_formatter.dart';
import 'package:flutter_hbb/yesdesk/theme.dart';
import 'package:flutter_hbb/yesdesk/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(Widget child,
    {Brightness brightness = Brightness.light, String language = 'en'}) {
  return MaterialApp(
    theme: ThemeData(brightness: brightness, useMaterial3: false),
    locale: Locale(language),
    supportedLocales: const [Locale('en'), Locale('ru')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    home: YesDeskTheme(child: Scaffold(body: child)),
  );
}

void main() {
  for (final brightness in Brightness.values) {
    for (final language in ['en', 'ru']) {
      testWidgets(
          'quick connect at 100/125/150% in ${brightness.name} ($language)',
          (tester) async {
        final isRussian = language == 'ru';
        final title = isRussian ? 'Быстрое подключение' : 'Quick connect';
        final connect = isRussian ? 'Подключиться' : 'Connect';
        final more = isRussian ? 'Ещё' : 'More';
        final transfer = isRussian ? 'Передача файлов' : 'Transfer file';
        final input = IDTextEditingController();
        addTearDown(input.dispose);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        var submitted = '';
        var transferRequested = false;

        await tester.pumpWidget(_app(
          Align(
            alignment: Alignment.topLeft,
            child: YesDeskQuickConnect(
              title: title,
              connectLabel: connect,
              field: TextField(
                controller: input,
                inputFormatters: [IDTextInputFormatter()],
                onSubmitted: (_) => submitted = input.id,
              ),
              onConnect: () => submitted = input.id,
              help: const SizedBox.shrink(),
              actions: PopupMenuButton<String>(
                tooltip: more,
                itemBuilder: (_) =>
                    [PopupMenuItem(value: transfer, child: Text(transfer))],
                onSelected: (_) => transferRequested = true,
              ),
            ),
          ),
          brightness: brightness,
          language: language,
        ));
        await tester.pumpAndSettle();

        for (final dpi in [1.0, 1.25, 1.5]) {
          tester.view.devicePixelRatio = dpi;
          tester.view.physicalSize = Size(540 * dpi, 460 * dpi);
          await tester.pumpAndSettle();
          expect(find.text(title), findsOneWidget);
          expect(find.text(connect).hitTestable(), findsOneWidget);
          expect(tester.takeException(), isNull);
        }

        await tester.enterText(find.byType(TextField), '123456789');
        expect(input.text, '123 456 789');
        tester.view.physicalSize = const Size(465, 525);
        await tester.pumpAndSettle();
        expect(input.text, '123 456 789');
        expect(tester.takeException(), isNull);

        await tester.testTextInput.receiveAction(TextInputAction.done);
        expect(submitted, '123456789');
        submitted = '';
        await tester.tap(find.text(connect));
        expect(submitted, '123456789');

        await tester.tap(find.byTooltip(more));
        await tester.pumpAndSettle();
        await tester.tap(find.text(transfer));
        await tester.pumpAndSettle();
        expect(transferRequested, isTrue);
      });
    }
  }

  testWidgets('compact support panel keeps the connection input mounted',
      (tester) async {
    tester.view.physicalSize = const Size(720, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var supportVisible = false;
    const inputKey = ValueKey('input');

    await tester.pumpWidget(_app(
      StatefulBuilder(
        builder: (context, setState) => YesDeskWorkspaceLayout(
          header: (compact) => TextButton(
            onPressed: compact
                ? () => setState(() => supportVisible = !supportVisible)
                : null,
            child: const Text('Support'),
          ),
          showSupport: supportVisible,
          main: const Align(
              alignment: Alignment.topLeft, child: TextField(key: inputKey)),
          support: const Text('Your desktop'),
        ),
      ),
    ));
    expect(find.text('Your desktop'), findsNothing);
    await tester.enterText(find.byKey(inputKey), 'remote-device');
    await tester.tap(find.text('Support'));
    await tester.pumpAndSettle();
    expect(find.byKey(inputKey), findsNothing);
    expect(find.text('Your desktop'), findsOneWidget);

    tester.view.physicalSize = const Size(1120, 700);
    await tester.pumpAndSettle();
    expect(find.text('remote-device'), findsOneWidget);
    expect(find.text('Your desktop'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('keyboard navigation and clipboard/password actions are usable',
      (tester) async {
    var selected = false;
    var copies = 0;
    var refreshes = 0;
    await tester.pumpWidget(_app(
      Column(
        children: [
          YesDeskNavItem(
            icon: Icons.star_border,
            label: 'Избранное',
            selected: false,
            compact: false,
            onPressed: () => selected = true,
          ),
          YesDeskCredential(
            label: 'Одноразовый пароль',
            value: '123456',
            copyLabel: 'Копировать',
            onCopy: () => copies++,
            actions: [
              YesDeskIconButton(
                label: 'Обновить пароль',
                icon: Icons.refresh,
                onPressed: () => refreshes++,
              ),
            ],
          ),
          const YesDeskCredential(
            label: 'ID',
            value: '—',
            copyLabel: 'Копировать ID',
            onCopy: null,
          ),
        ],
      ),
      language: 'ru',
    ));
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(selected, isTrue);

    await tester.tap(find.byTooltip('Копировать'));
    await tester.tap(find.byTooltip('Обновить пароль'));
    expect(copies, 1);
    expect(refreshes, 1);
    expect(find.byTooltip('Копировать ID'), findsNothing);
  });

  testWidgets('device table reflows and keeps action available',
      (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(820, 500);
    var actions = 0;
    await tester.pumpWidget(_app(
      Column(children: [
        const YesDeskDeviceRow(
          header: true,
          name: 'Устройство',
          id: 'ID',
          platform: 'Платформа',
          status: 'Статус',
        ),
        YesDeskDeviceRow(
          name: 'Длинное имя рабочего компьютера из адресной книги',
          id: '123 456 789',
          platform: 'Windows',
          status: 'В сети',
          detail: 'support-host',
          action: YesDeskIconButton(
            label: 'Ещё',
            icon: Icons.more_horiz,
            onPressed: () => actions++,
          ),
        ),
      ]),
      brightness: Brightness.dark,
      language: 'ru',
    ));
    expect(find.text('Windows'), findsOneWidget);
    expect(find.text('123 456 789'), findsOneWidget);
    await tester.tap(find.byTooltip('Ещё'));
    expect(actions, 1);

    tester.view.physicalSize = const Size(350, 500);
    await tester.pumpAndSettle();
    expect(find.text('Windows'), findsNothing);
    expect(find.text('123 456 789 · support-host'), findsOneWidget);
    expect(find.text('В сети'), findsOneWidget);
    await tester.tap(find.byTooltip('Ещё'));
    expect(actions, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('system theme follows platform brightness', (tester) async {
    final dispatcher = tester.platformDispatcher;
    addTearDown(dispatcher.clearPlatformBrightnessTestValue);
    dispatcher.platformBrightnessTestValue = Brightness.light;
    const marker = ValueKey('theme-surface');
    await tester.pumpWidget(MaterialApp(
      theme: YesDeskTheme.apply(ThemeData.light()),
      darkTheme: YesDeskTheme.apply(ThemeData.dark()),
      themeMode: ThemeMode.system,
      home: const Scaffold(body: SizedBox(key: marker)),
    ));
    expect(YesDeskColors.of(tester.element(find.byKey(marker))),
        YesDeskColors.light);

    dispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pumpAndSettle();
    expect(YesDeskColors.of(tester.element(find.byKey(marker))),
        YesDeskColors.dark);
  });

  test('both palettes meet AA contrast for text, accents and warning states',
      () {
    double ratio(Color a, Color b) {
      final first = a.computeLuminance();
      final second = b.computeLuminance();
      return first >= second
          ? (first + .05) / (second + .05)
          : (second + .05) / (first + .05);
    }

    for (final palette in [YesDeskColors.light, YesDeskColors.dark]) {
      expect(ratio(palette.text, palette.canvas), greaterThanOrEqualTo(4.5));
      expect(ratio(palette.muted, palette.surface), greaterThanOrEqualTo(4.5));
      expect(
          ratio(palette.accent, palette.selected), greaterThanOrEqualTo(4.5));
      expect(
          ratio(palette.onAccent, palette.accent), greaterThanOrEqualTo(4.5));
      expect(ratio(palette.warning, palette.canvas), greaterThanOrEqualTo(4.5));
      expect(ratio(palette.error, palette.canvas), greaterThanOrEqualTo(4.5));
    }
  });
}
