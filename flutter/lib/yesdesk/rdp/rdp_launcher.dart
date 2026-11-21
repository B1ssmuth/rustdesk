import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;
import 'package:win32/win32.dart';

import 'rdp_profile.dart';

typedef StartMstsc = Future<Process> Function(
    String executable, List<String> args);

class RdpLauncher {
  RdpLauncher({
    String Function()? executable,
    StartMstsc? start,
    Directory? temporaryRoot,
  })  : _executable = executable ?? _systemMstsc,
        _start = start ?? _startProcess,
        _temporaryRoot = temporaryRoot;

  final String Function() _executable;
  final StartMstsc _start;
  final Directory? _temporaryRoot;

  static String _systemMstsc() {
    if (!Platform.isWindows) throw UnsupportedError('MSTSC requires Windows');
    final buffer = calloc<Uint16>(MAX_PATH).cast<Utf16>();
    try {
      final length = GetSystemDirectory(buffer, MAX_PATH);
      if (length == 0 || length >= MAX_PATH) {
        throw const FileSystemException('Windows system directory unavailable');
      }
      return p.windows.join(buffer.toDartString(length: length), 'mstsc.exe');
    } finally {
      calloc.free(buffer);
    }
  }

  static Future<Process> _startProcess(String executable, List<String> args) =>
      Process.start(executable, args, runInShell: false);

  /// Returns the process exit status, which is not an RDP connection status.
  Future<({Future<int> exitCode})> launch(RdpProfile profile) async {
    final executable = _executable();
    final directory = await (_temporaryRoot ?? Directory.systemTemp)
        .createTemp('yesdesk-rdp-');
    try {
      final file = File(p.join(directory.path, 'session.rdp'));
      // MSTSC's Unicode connection file format uses a UTF-16LE BOM.
      final bytes = <int>[0xff, 0xfe];
      for (final unit in rdpConnectionFile(profile).codeUnits) {
        bytes.addAll([unit & 0xff, unit >> 8]);
      }
      await file.writeAsBytes(bytes, flush: true);
      final process = await _start(executable, [file.path]);
      process.stdout.drain<void>().ignore();
      process.stderr.drain<void>().ignore();
      return (exitCode: _watchExit(process, directory));
    } catch (_) {
      await _cleanup(directory);
      rethrow;
    }
  }

  static Future<int> _watchExit(Process process, Directory directory) async {
    try {
      return await process.exitCode;
    } finally {
      await _cleanup(directory);
    }
  }

  static Future<void> _cleanup(Directory directory) async {
    try {
      await directory.delete(recursive: true);
    } on FileSystemException {
      // OS cleanup can remove the credential-free file if the client still
      // holds a handle or YES Desk is closed before the process exits.
    }
  }
}
