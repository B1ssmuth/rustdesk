import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

abstract interface class CredentialStore {
  bool get canPersist;
  String? read(String reference);
  bool write(String reference, String value);
  bool delete(String reference);
}

/// Generic credentials are stored by Windows in the interactive user's vault.
class WindowsCredentialStore implements CredentialStore {
  const WindowsCredentialStore(this.namespace);

  final String namespace;

  @override
  bool get canPersist => Platform.isWindows;

  static const _maxBlob = 2560;
  static const _type = CRED_TYPE.CRED_TYPE_GENERIC;
  String _target(String reference) => 'YES Desk/$namespace/$reference';

  @override
  String? read(String reference) {
    if (!canPersist) return null;
    return using((arena) {
      final result = arena<Pointer<CREDENTIAL>>();
      if (CredRead(_target(reference).toNativeUtf16(allocator: arena), _type, 0,
              result) ==
          0) {
        return null;
      }
      try {
        final credential = result.value.ref;
        final bytes = credential.CredentialBlob.asTypedList(
            credential.CredentialBlobSize);
        try {
          return utf8.decode(bytes);
        } finally {
          bytes.fillRange(0, bytes.length, 0);
        }
      } finally {
        CredFree(result.value);
      }
    });
  }

  @override
  bool write(String reference, String value) {
    if (!canPersist) return false;
    final bytes = utf8.encode(value);
    try {
      if (bytes.isEmpty || bytes.length > _maxBlob) return false;
      return using((arena) {
        final blob = arena<Uint8>(bytes.length);
        final native = blob.asTypedList(bytes.length)..setAll(0, bytes);
        try {
          final credential = arena<CREDENTIAL>();
          credential.ref
            ..Type = _type
            ..TargetName = _target(reference).toNativeUtf16(allocator: arena)
            ..Persist = CRED_PERSIST.CRED_PERSIST_LOCAL_MACHINE
            ..CredentialBlobSize = bytes.length
            ..CredentialBlob = blob;
          return CredWrite(credential, 0) != 0;
        } finally {
          native.fillRange(0, native.length, 0);
        }
      });
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  @override
  bool delete(String reference) {
    if (!canPersist) return false;
    return using((arena) {
      final deleted = CredDelete(
        _target(reference).toNativeUtf16(allocator: arena),
        _type,
        0,
      );
      return deleted != 0 || GetLastError() == WIN32_ERROR.ERROR_NOT_FOUND;
    });
  }
}
