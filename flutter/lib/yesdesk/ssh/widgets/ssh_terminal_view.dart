import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../../widgets.dart';
import '../controllers/ssh_tab.dart';
import '../models/ssh_profile.dart';
import 'ssh_dialogs.dart';
import 'ssh_strings.dart';

class SshTerminalView extends StatefulWidget {
  const SshTerminalView({super.key, required this.tab, required this.labels});
  final SshTab tab;
  final SshStrings labels;

  @override
  State<SshTerminalView> createState() => _SshTerminalViewState();
}

class _SshTerminalViewState extends State<SshTerminalView> {
  final _selection = TerminalController();
  final _scroll = ScrollController();
  final _focus = FocusNode();
  bool _pasting = false;
  SshTab get tab => widget.tab;
  SshStrings get l => widget.labels;

  @override
  void dispose() {
    _selection.clearSelection();
    _selection.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _copy() {
    final selection = _selection.selection;
    if (selection != null) {
      unawaited(Clipboard.setData(
        ClipboardData(text: tab.terminal.buffer.getText(selection)),
      ));
    }
  }

  Future<void> _paste() async {
    final run = tab.run;
    if (_pasting || run == null || !run.active) return;
    _pasting = true;
    try {
      final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
      if (!mounted || tab.run != run || !run.active) return;
      // Remove embedded control sequences (including bracketed-paste delimiters)
      // and retain tabs and line breaks for normal terminal paste.
      final text = clipboard?.text?.replaceAll(
        RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f]'),
        '',
      );
      if (text == null || text.isEmpty) return;
      if (text.length > 64 * 1024) {
        await sshConfirm(
          context,
          l,
          l.text('Clipboard text exceeds 64 KiB',
              'Текст в буфере превышает 64 КиБ'),
          l.close,
        );
        return;
      }
      if (text.contains('\n') || text.contains('\r')) {
        final accepted = await sshConfirm(
          context,
          l,
          l.text('Paste multiple lines?', 'Вставить несколько строк?'),
          l.text('Paste', 'Вставить'),
          content: Text(l.text(
            'Line breaks can cause the remote shell to run commands.',
            'Переносы строк могут запустить команды в удалённой оболочке.',
          )),
        );
        if (!accepted) return;
      }
      if (mounted && tab.run == run && run.active) {
        _focus.requestFocus();
        tab.terminal.paste(text);
      }
    } on PlatformException {
      if (mounted) {
        await sshConfirm(
            context,
            l,
            l.text('Clipboard is unavailable', 'Буфер обмена недоступен'),
            l.close);
      }
    } finally {
      _pasting = false;
    }
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    final shortcut = keyboard.isMetaPressed ||
        (keyboard.isControlPressed && keyboard.isShiftPressed);
    if (!shortcut) return KeyEventResult.ignored;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.keyC:
        _copy();
      case LogicalKeyboardKey.keyV:
        unawaited(_paste());
      case LogicalKeyboardKey.keyF:
        unawaited(_search());
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  Future<void> _search() async {
    final query = await sshTextDialog(
      context,
      l,
      l.text('Find in terminal', 'Поиск в терминале'),
    );
    if (!mounted || query == null) return;
    final buffer = tab.terminal.buffer;
    final needle = query.toLowerCase();
    final matches = <({int row, String text, Object line})>[];
    for (var index = buffer.lines.length - 1; index >= 0; index--) {
      final line = buffer.lines[index];
      final text = line.getText();
      if (text.toLowerCase().contains(needle)) {
        matches.add((row: index, text: text, line: line));
      }
      if (matches.length == 250) break;
    }
    final match = await sshDialog(
        context,
        (context) => AlertDialog(
              title: Text(l.text('Search results', 'Результаты поиска')),
              content: SizedBox(
                width: 560,
                height: 320,
                child: matches.isEmpty
                    ? Center(
                        child: Text(l.text('No matches', 'Совпадений нет')))
                    : ListView.builder(
                        itemCount: matches.length,
                        itemBuilder: (context, index) {
                          final result = matches[index];
                          return ListTile(
                            title: Text(result.text,
                                maxLines: 2, overflow: TextOverflow.ellipsis),
                            onTap: () => Navigator.pop(context, result),
                          );
                        },
                      ),
              ),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(l.close))
              ],
            ));
    if (!mounted || match == null || buffer != tab.terminal.buffer) return;
    final result = match as ({int row, String text, Object line});
    // Scrollback can rotate while the results dialog is open.
    var row = result.row;
    if (row >= buffer.lines.length ||
        !identical(result.line, buffer.lines[row])) {
      row = -1;
      for (var index = 0; index < buffer.lines.length; index++) {
        if (identical(result.line, buffer.lines[index])) {
          row = index;
          break;
        }
      }
    }
    if (row < 0) return;
    _selection.setSelection(
      buffer.createAnchor(0, row),
      buffer.createAnchor(buffer.lines[row].length, row),
    );
    if (_scroll.hasClients) {
      final position = _scroll.position;
      final hidden = buffer.lines.length - tab.terminal.viewHeight;
      if (hidden > 0) {
        final firstRow = (row - tab.terminal.viewHeight ~/ 2).clamp(0, hidden);
        _scroll.jumpTo(position.maxScrollExtent * firstRow / hidden);
      }
    }
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: tab,
        builder: (context, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              children: [
                YesDeskIconButton(
                    label: l.text('Copy', 'Копировать'),
                    icon: Icons.copy,
                    onPressed: _copy),
                YesDeskIconButton(
                    label: l.text('Paste', 'Вставить'),
                    icon: Icons.content_paste,
                    onPressed: tab.run?.active == true ? _paste : null),
                YesDeskIconButton(
                    label: l.text('Find in terminal', 'Поиск в терминале'),
                    icon: Icons.search,
                    onPressed: _search),
                YesDeskIconButton(
                    label: l.text('Decrease font size', 'Уменьшить шрифт'),
                    icon: Icons.text_decrease,
                    onPressed: () => tab.zoom(-1)),
                YesDeskIconButton(
                    label: l.text('Increase font size', 'Увеличить шрифт'),
                    icon: Icons.text_increase,
                    onPressed: () => tab.zoom(1)),
                YesDeskIconButton(
                    label: l.text('Clear screen and scrollback',
                        'Очистить экран и историю'),
                    icon: Icons.layers_clear_outlined,
                    onPressed: () {
                      _selection.clearSelection();
                      tab.terminal.write('\x1b[2J\x1b[3J\x1b[H');
                    }),
              ],
            ),
            Expanded(
              child: TerminalView(
                tab.terminal,
                controller: _selection,
                scrollController: _scroll,
                focusNode: _focus,
                autofocus: true,
                theme: tab.profile.palette == SshPalette.dark
                    ? TerminalThemes.defaultTheme
                    : _light,
                textStyle: TerminalStyle(fontSize: tab.fontSize),
                hardwareKeyboardOnly: true,
                shortcuts: const {},
                onKeyEvent: _key,
              ),
            ),
          ],
        ),
      );
}

const _light = TerminalTheme(
  cursor: Color(0xff222222),
  selection: Color(0x55999999),
  foreground: Color(0xff252525),
  background: Color(0xfff6f6f6),
  black: Color(0xff151515),
  white: Color(0xff5e5e5e),
  red: Color(0xffad1825),
  green: Color(0xff17642c),
  yellow: Color(0xff7b5700),
  blue: Color(0xff174c98),
  magenta: Color(0xff874181),
  cyan: Color(0xff006575),
  brightBlack: Color(0xff656565),
  brightRed: Color(0xffbb2b35),
  brightGreen: Color(0xff1a7737),
  brightYellow: Color(0xff795723),
  brightBlue: Color(0xff275db1),
  brightMagenta: Color(0xff90318b),
  brightCyan: Color(0xff126c73),
  brightWhite: Color(0xff9a9a9a),
  searchHitBackground: Color(0xffe6dbb3),
  searchHitBackgroundCurrent: Color(0xffdbc688),
  searchHitForeground: Color(0xff151515),
);
