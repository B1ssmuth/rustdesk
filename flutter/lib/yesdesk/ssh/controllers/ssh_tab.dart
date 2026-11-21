import 'dart:async';

import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import '../models/ssh_profile.dart';
import '../services/ssh_transport.dart';
import '../storage/ssh_repository.dart';

class SshTab extends ChangeNotifier {
  SshTab(this.profile, this.trust, {this.filesOnly = false})
      : title = profile.name,
        fontSize = profile.fontSize,
        terminal = Terminal(maxLines: profile.scrollback) {
    // With no onPrivateOSC callback, xterm discards OSC 52.
    terminal.onOutput = (text) => run?.write(text);
    terminal.onResize = (columns, rows, width, height) {
      if (columns < 1 || rows < 1) return;
      _size = (columns: columns, rows: rows, width: width, height: height);
      run?.resize();
    };
  }

  final SshProfile profile;
  final SshHostTrust trust;
  final Terminal terminal;
  final bool filesOnly;
  bool showFiles = false;
  bool filesOpened = false;
  double filesWidth = 390;

  void toggleFiles() {
    showFiles = !showFiles;
    if (showFiles) filesOpened = true;
    notifyListeners();
  }

  void resizeFiles(double width) {
    filesWidth = width;
    notifyListeners();
  }

  String title;
  double fontSize;

  bool _disposed = false;
  SshRun? run;
  SshPhase phase = SshPhase.idle;
  SshSize _size = (columns: 80, rows: 24, width: 0, height: 0);

  bool get busy => switch (phase) {
        SshPhase.connecting ||
        SshPhase.verifyingHost ||
        SshPhase.authenticating ||
        SshPhase.active ||
        SshPhase.closing =>
          true,
        _ => false,
      };

  void connect(SshPrompts prompts) {
    if (busy) return;
    final attempt = SshRun(
      profile: profile,
      trust: trust,
      prompts: prompts,
      onPhase: (value) {
        phase = value;
        if (!_disposed) notifyListeners();
      },
      onText: terminal.write,
      size: () => _size,
      terminal: !filesOnly,
    );
    run = attempt;
    unawaited(attempt.start());
  }

  void rename(String name) {
    title = name;
    notifyListeners();
  }

  void zoom(double delta) {
    fontSize = (fontSize + delta).clamp(8, 36).toDouble();
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    run?.cancel();
    terminal.onOutput = null;
    terminal.onResize = null;
    super.dispose();
  }
}
