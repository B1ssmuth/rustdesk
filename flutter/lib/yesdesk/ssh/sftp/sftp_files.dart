import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'package:win32/win32.dart';

enum FileProblem {
  invalidName,
  alreadyExists,
  changed,
  unsafeType,
  noAtomicReplace,
  metadata,
  incomplete,
  text
}

class FileOperationError implements Exception {
  const FileOperationError(this.problem);
  final FileProblem problem;
}

class TransferCancelled implements Exception {
  const TransferCancelled();
}

typedef ConfirmReplace = Future<bool> Function(String path);
typedef RemoteVersion = (int?, int?, int?, int?, int?);

class TransferProgress {
  int bytes = 0;
  int? total;
  bool cancelled = false;
  bool publishing = false;
  final clock = Stopwatch();
  String? leftover;

  void check() {
    if (cancelled) throw const TransferCancelled();
  }
}

String remoteChild(String directory, String name) {
  if (name.isEmpty ||
      name == '.' ||
      name == '..' ||
      name.contains('/') ||
      name.contains('\x00')) {
    throw const FileOperationError(FileProblem.invalidName);
  }
  return p.posix.join(directory, name);
}

// A server may be Windows, where backslashes and alternate streams are
// interpreted as paths rather than ordinary characters in a new name.
void _validatePortableName(String name) {
  if (name.isEmpty ||
      name == '.' ||
      name == '..' ||
      RegExp(r'[<>:"/\\|?*\x00-\x1f]').hasMatch(name) ||
      name.endsWith('.') ||
      name.endsWith(' ') ||
      RegExp(r'^(con|prn|aux|nul|conin\$|conout\$|com[0-9¹²³]|lpt[0-9¹²³])$',
              caseSensitive: false)
          .hasMatch(name.split('.').first.trimRight())) {
    throw const FileOperationError(FileProblem.invalidName);
  }
}

/// A directory explicitly chosen by the operator. Navigation and downloads
/// use canonical directories beneath this root and never follow file links.
class LocalFiles {
  LocalFiles._(this.root);
  final String root;

  static Future<LocalFiles> open(String path) async =>
      LocalFiles._(await Directory(path).resolveSymbolicLinks());

  Future<String> directory(String path) async {
    final resolved = await Directory(path).resolveSymbolicLinks();
    if (!p.equals(root, resolved) && !p.isWithin(root, resolved)) {
      throw const FileOperationError(FileProblem.invalidName);
    }
    return resolved;
  }

  Future<String> child(String parent, String name) async {
    _validatePortableName(name);
    return p.join(await directory(parent), name);
  }
}

class RemoteText {
  const RemoteText(this.path, this.original, this.attrs);
  final String path;
  final String original;
  final SftpFileAttrs attrs;
}

class SftpFiles {
  SftpFiles(this.client, this.timeout);
  final SftpClient client;
  final Duration timeout;
  static const textLimit = 512 * 1024;

  Future<T> request<T>(Future<T> operation) => operation.timeout(
        timeout,
        onTimeout: () {
          client.close().ignore();
          throw TimeoutException('SFTP request timed out', timeout);
        },
      );

  Future<SftpFileAttrs?> _stat(String path) async {
    try {
      return await request(client.stat(path, followLink: false));
    } on SftpStatusError catch (error) {
      if (error.code == SftpStatusCode.noSuchFile) return null;
      rethrow;
    }
  }

  RemoteVersion? _version(SftpFileAttrs? attrs) => attrs == null
      ? null
      : (
          attrs.size,
          attrs.modifyTime,
          attrs.mode?.value,
          attrs.userID,
          attrs.groupID
        );

  Future<String> createEmptyFile(String directory, String name) async {
    _validatePortableName(name);
    final path = remoteChild(directory, name);
    try {
      final handle = await request(client.open(path,
          mode: SftpFileOpenMode.write |
              SftpFileOpenMode.create |
              SftpFileOpenMode.exclusive));
      await request(handle.close());
      return path;
    } on SftpStatusError catch (error) {
      // SFTP v3 commonly reports an exclusive-open conflict as FAILURE.
      if (error.code == SftpStatusCode.failure && await _stat(path) != null) {
        throw const FileOperationError(FileProblem.alreadyExists);
      }
      rethrow;
    }
  }

  Future<void> rename(String source, String target) =>
      request(client.rename(source, target, replace: false));

  Future<void> delete(String path, SftpFileType? expected) async {
    final attrs = await _stat(path);
    if (attrs == null || attrs.type != expected) {
      throw const FileOperationError(FileProblem.changed);
    }
    await request(attrs.isDirectory ? client.rmdir(path) : client.remove(path));
  }

  Future<void> upload(File source, String target, TransferProgress progress,
      ConfirmReplace confirm) async {
    if (await FileSystemEntity.type(source.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw const FileOperationError(FileProblem.unsafeType);
    }
    final initial = await source.stat();
    final existing = await _stat(target);
    if (existing != null) {
      if (!existing.isFile) {
        throw const FileOperationError(FileProblem.unsafeType);
      }
      if (!await confirm(target)) throw const TransferCancelled();
    }
    await _write(target, _readLocal(source), initial.size, existing, progress,
        () async {
      final after = await source.stat();
      if (after.size != initial.size ||
          after.modified != initial.modified ||
          after.changed != initial.changed ||
          _version(await _stat(target)) != _version(existing)) {
        throw const FileOperationError(FileProblem.changed);
      }
    });
  }

  Stream<Uint8List> _readLocal(File source) async* {
    final file = await source.open();
    try {
      while (true) {
        final block = await file.read(512 * 1024);
        if (block.isEmpty) break;
        yield block;
      }
    } finally {
      await file.close();
    }
  }

  Future<void> _write(
    String target,
    Stream<Uint8List> input,
    int length,
    SftpFileAttrs? originalAttrs,
    TransferProgress progress,
    Future<void> Function() verify,
  ) async {
    final replace = originalAttrs != null;
    if (replace) {
      final handshake = await request(client.handshake);
      if (handshake.extensions['posix-rename@openssh.com'] != '1') {
        throw const FileOperationError(FileProblem.noAtomicReplace);
      }
      await verify();
      // Verify server-side write access without truncating the original.
      final original =
          await request(client.open(target, mode: SftpFileOpenMode.write));
      try {
        if (_version(await request(original.stat())) !=
            _version(originalAttrs)) {
          throw const FileOperationError(FileProblem.changed);
        }
      } finally {
        await request(original.close());
      }
    }
    progress.check();
    progress.total = length;
    final temporary = remoteChild(
        p.posix.dirname(target), '.yesdesk-${const Uuid().v4()}.part');
    var owned = false;
    try {
      final file = await request(client.open(
        temporary,
        mode: SftpFileOpenMode.write |
            SftpFileOpenMode.create |
            SftpFileOpenMode.exclusive,
        attrs: SftpFileAttrs(mode: const SftpFileMode.value(0x180)), // 0600
      ));
      owned = true;
      try {
        await for (final chunk in input) {
          progress.check();
          if (progress.bytes + chunk.length > length) {
            throw const FileOperationError(FileProblem.changed);
          }
          await request(file.writeBytes(chunk, offset: progress.bytes));
          progress.bytes += chunk.length;
        }
        final staged = await request(file.stat());
        if (progress.bytes != length || staged.size != length) {
          throw const FileOperationError(FileProblem.incomplete);
        }
        if (originalAttrs != null) {
          final mode = originalAttrs.mode;
          final uid = originalAttrs.userID;
          final gid = originalAttrs.groupID;
          final ownerChanged = uid != staged.userID || gid != staged.groupID;
          if (mode == null || (ownerChanged && (uid == null || gid == null))) {
            throw const FileOperationError(FileProblem.metadata);
          }
          final permissions = mode.value & 0x1ff;
          await request(file.setStat(SftpFileAttrs(
            mode: SftpFileMode.value(permissions),
            userID: ownerChanged ? uid : null,
            groupID: ownerChanged ? gid : null,
          )));
          final result = await request(file.stat());
          if (result.userID != uid ||
              result.groupID != gid ||
              ((result.mode?.value ?? -1) & 0x1ff) != permissions) {
            throw const FileOperationError(FileProblem.metadata);
          }
        }
      } finally {
        await request(file.close());
      }
      await verify();
      progress.check();
      progress.publishing = true;
      await request(client.rename(temporary, target, replace: replace));
      owned = false;
    } finally {
      if (owned) {
        try {
          await request(client.remove(temporary));
        } catch (_) {
          progress.leftover = temporary;
        }
      }
    }
  }

  Future<void> download(String source, LocalFiles local, String directory,
      String name, TransferProgress progress, ConfirmReplace confirm) async {
    final target = await local.child(directory, name);
    final attrs = await _stat(source);
    final length = attrs?.size;
    if (attrs == null || !attrs.isFile || length == null || length < 0) {
      throw const FileOperationError(FileProblem.unsafeType);
    }
    Future<(FileSystemEntityType, int?, DateTime?, DateTime?)>
        snapshot() async {
      final type = await FileSystemEntity.type(target, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        return (type, null, null, null);
      }
      if (type != FileSystemEntityType.file) {
        throw const FileOperationError(FileProblem.unsafeType);
      }
      final stat = await FileStat.stat(target);
      return (type, stat.size, stat.modified, stat.changed);
    }

    final original = await snapshot();
    if (original.$1 != FileSystemEntityType.notFound &&
        !await confirm(target)) {
      throw const TransferCancelled();
    }
    progress.check();
    progress.total = length;
    if (!p.equals(await local.directory(directory), p.dirname(target))) {
      throw const FileOperationError(FileProblem.changed);
    }
    final staging = await Directory(p.dirname(target)).createTemp('.yesdesk-');
    final temporary = File(p.join(staging.path, 'download.part'));
    try {
      final file = await request(client.open(source));
      try {
        if (_version(await request(file.stat())) != _version(attrs)) {
          throw const FileOperationError(FileProblem.changed);
        }
        final output = await temporary.open(mode: FileMode.write);
        try {
          final stream = file
              .read(
                length: length,
                chunkSize: 64 * 1024,
                maxPendingRequests: 16,
              )
              .timeout(timeout);
          await for (final chunk in stream) {
            progress.check();
            await output.writeFrom(chunk);
            progress.bytes += chunk.length;
          }
          if (progress.bytes != length || await output.length() != length) {
            throw const FileOperationError(FileProblem.incomplete);
          }
          await output.flush();
        } on TimeoutException {
          client.close().ignore();
          rethrow;
        } finally {
          await output.close();
        }
        if (_version(await request(file.stat())) != _version(attrs)) {
          throw const FileOperationError(FileProblem.changed);
        }
      } finally {
        await request(file.close());
      }
      if (!p.equals(await local.directory(directory), p.dirname(target)) ||
          await snapshot() != original) {
        throw const FileOperationError(FileProblem.changed);
      }
      progress.check();
      progress.publishing = true;
      if (original.$1 == FileSystemEntityType.notFound) {
        _publishNewLocal(temporary.path, target);
      } else {
        await temporary.rename(target);
      }
    } finally {
      // Delete only our known file and directory, never a recursive tree.
      try {
        if (p.equals(await local.directory(directory), p.dirname(target)) &&
            p.equals(await local.directory(staging.path), staging.path)) {
          if (await temporary.exists()) await temporary.delete();
          await staging.delete();
        } else {
          progress.leftover = staging.path;
        }
      } catch (_) {
        progress.leftover = staging.path;
      }
    }
  }

  // Windows MoveFile and POSIX link both fail if a name appears after
  // confirmation. Staging and destination share the same filesystem.
  void _publishNewLocal(String source, String target) {
    using((arena) {
      if (Platform.isWindows) {
        if (MoveFile(source.toNativeUtf16(allocator: arena),
                target.toNativeUtf16(allocator: arena)) ==
            0) {
          throw FileSystemException('Could not publish download', target,
              OSError('MoveFile', GetLastError()));
        }
      } else if (Platform.isLinux || Platform.isMacOS) {
        if (_link(source.toNativeUtf8(allocator: arena),
                target.toNativeUtf8(allocator: arena)) !=
            0) {
          throw FileSystemException('Could not publish download', target);
        }
      } else {
        throw const FileOperationError(FileProblem.noAtomicReplace);
      }
    });
  }

  static final _link = DynamicLibrary.process().lookupFunction<
      Int Function(Pointer<Utf8>, Pointer<Utf8>),
      int Function(Pointer<Utf8>, Pointer<Utf8>)>('link');

  Future<RemoteText> readText(String path) async {
    final attrs = await _stat(path);
    final length = attrs?.size;
    if (attrs == null ||
        !attrs.isFile ||
        length == null ||
        length < 0 ||
        length > textLimit) {
      throw const FileOperationError(FileProblem.text);
    }
    final file = await request(client.open(path));
    try {
      final bytes = await request(file.readBytes(length: textLimit + 1));
      final version = _version(attrs)!;
      if (bytes.length != length ||
          _version(await request(file.stat())) != version ||
          _version(await _stat(path)) != version) {
        throw const FileOperationError(FileProblem.changed);
      }
      try {
        final decoded = utf8.decode(bytes);
        if (RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]').hasMatch(decoded)) {
          throw const FormatException();
        }
        // Utf8Decoder removes a BOM. Preserve it on save when present.
        final bom = bytes.length >= 3 &&
            bytes[0] == 0xef &&
            bytes[1] == 0xbb &&
            bytes[2] == 0xbf;
        return RemoteText(path, bom ? '\ufeff$decoded' : decoded, attrs);
      } on FormatException {
        throw const FileOperationError(FileProblem.text);
      }
    } finally {
      await request(file.close());
    }
  }

  Future<void> saveText(
      RemoteText original, String text, TransferProgress progress) async {
    final bytes = utf8.encode(text);
    if (bytes.length > textLimit) {
      throw const FileOperationError(FileProblem.text);
    }
    await _write(original.path, Stream.value(Uint8List.fromList(bytes)),
        bytes.length, original.attrs, progress, () async {
      final latest = await readText(original.path);
      if (_version(latest.attrs) != _version(original.attrs) ||
          latest.original != original.original) {
        throw const FileOperationError(FileProblem.changed);
      }
    });
  }
}
