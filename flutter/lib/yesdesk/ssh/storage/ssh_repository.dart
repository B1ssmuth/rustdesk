import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/ssh_profile.dart';

class SshHostKey {
  const SshHostKey(this.algorithm, this.fingerprint);

  final String algorithm;
  final String fingerprint;

  bool matches(SshHostKey other) =>
      algorithm == other.algorithm && fingerprint == other.fingerprint;

  Map<String, String> toJson() =>
      {'algorithm': algorithm, 'fingerprint': fingerprint};

  factory SshHostKey.fromJson(Map<String, dynamic> json) =>
      SshHostKey(json['algorithm'] as String, json['fingerprint'] as String);
}

abstract interface class SshHostTrust {
  Future<SshHostKey?> lookup(String endpoint);

  /// Returns an existing different key if trust was established concurrently.
  Future<SshHostKey?> remember(String endpoint, SshHostKey candidate);
}

class SshRepository implements SshHostTrust {
  SshRepository([Future<Directory> Function()? directory])
      : _directory = directory ?? _defaultDirectory;

  final Future<Directory> Function() _directory;
  Future<void> _pending = Future.value();

  static Future<Directory> _defaultDirectory() async {
    final support = await getApplicationSupportDirectory();
    return Directory(p.join(support.path, 'ssh'));
  }

  Future<T> _transaction<T>(
    String name,
    Future<T> Function(Map<String, dynamic> data, File file) action,
  ) {
    final operation = _pending.then((_) async {
      final directory = await _directory();
      await directory.create(recursive: true);
      final lock = await File(p.join(directory.path, '$name.lock'))
          .open(mode: FileMode.append);
      try {
        await lock.lock(FileLock.blockingExclusive);
        final file = File(p.join(directory.path, '$name.json'));
        final data = await file.exists()
            ? jsonDecode(await file.readAsString()) as Map<String, dynamic>
            : <String, dynamic>{};
        return await action(data, file);
      } finally {
        await lock.close();
      }
    });
    _pending =
        operation.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return operation;
  }

  Future<void> _write(File file, Map<String, dynamic> data) async {
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(jsonEncode(data), flush: true);
    await temporary.rename(file.path);
  }

  Future<({List<SshProfile> profiles, List<String> groups})> load() =>
      _transaction('profiles', (data, _) async {
        final profiles = data['profiles'] as Map<String, dynamic>? ?? {};
        return (
          profiles: profiles.values
              .map((json) => SshProfile.fromJson(json as Map<String, dynamic>))
              .toList(),
          groups: (data['groups'] as List<dynamic>? ?? []).cast<String>(),
        );
      });

  Future<String?> save(SshProfile profile, {bool clearSecret = false}) =>
      _transaction('profiles', (data, file) async {
        final profiles = data.putIfAbsent('profiles', () => <String, dynamic>{})
            as Map<String, dynamic>;
        final previous = profiles[profile.id] as Map<String, dynamic>?;
        final current = previous == null ? null : SshProfile.fromJson(previous);
        final retained = current != null &&
                !clearSecret &&
                current.endpoint == profile.endpoint &&
                current.username == profile.username &&
                current.auth == profile.auth &&
                current.filesOnly == profile.filesOnly
            ? current.secretRef
            : null;
        profiles[profile.id] = profile.withSecret(retained).toJson();
        if (profile.group.isNotEmpty) {
          final groups = data.putIfAbsent('groups', () => <String>[]) as List;
          if (!groups.contains(profile.group)) groups.add(profile.group);
        }
        await _write(file, data);
        return current?.secretRef == retained ? null : current?.secretRef;
      });

  Future<void> setFavorite(String id, bool value) =>
      _transaction('profiles', (data, file) async {
        final profiles = data['profiles'] as Map<String, dynamic>?;
        final profile = profiles?[id] as Map<String, dynamic>?;
        if (profile == null) return;
        profile['favorite'] = value;
        await _write(file, data);
      });

  Future<({bool saved, String? previous})> attachSecret(
    SshProfile profile,
    String reference,
  ) =>
      _transaction('profiles', (data, file) async {
        final profiles = data['profiles'] as Map<String, dynamic>?;
        final json = profiles?[profile.id] as Map<String, dynamic>?;
        if (json == null) return (saved: false, previous: null);
        final current = SshProfile.fromJson(json);
        if (current.endpoint != profile.endpoint ||
            current.username != profile.username ||
            current.auth != profile.auth ||
            current.filesOnly != profile.filesOnly) {
          return (saved: false, previous: null);
        }
        profiles![profile.id] = current.withSecret(reference).toJson();
        await _write(file, data);
        return (saved: true, previous: current.secretRef);
      });

  Future<String?> delete(String id) =>
      _transaction('profiles', (data, file) async {
        final profiles = data['profiles'] as Map<String, dynamic>?;
        final removed = profiles?.remove(id) as Map<String, dynamic>?;
        if (removed != null) await _write(file, data);
        return removed?['secretRef'] as String?;
      });

  Future<void> addGroup(String group) => _transaction('profiles', (data, file) {
        final groups = data.putIfAbsent('groups', () => <String>[]) as List;
        if (!groups.contains(group)) groups.add(group);
        return _write(file, data);
      });

  @override
  Future<SshHostKey?> lookup(String endpoint) =>
      _transaction('known-hosts', (data, _) async {
        final stored = data[endpoint] as Map<String, dynamic>?;
        return stored == null ? null : SshHostKey.fromJson(stored);
      });

  @override
  Future<SshHostKey?> remember(String endpoint, SshHostKey candidate) =>
      _transaction('known-hosts', (data, file) async {
        final stored = data[endpoint] as Map<String, dynamic>?;
        if (stored != null) {
          final current = SshHostKey.fromJson(stored);
          return current.matches(candidate) ? null : current;
        }
        data[endpoint] = candidate.toJson();
        await _write(file, data);
        return null;
      });
  Future<bool> removeTrust(String endpoint, SshHostKey expected) =>
      _transaction('known-hosts', (data, file) async {
        final stored = data[endpoint] as Map<String, dynamic>?;
        if (stored == null || !SshHostKey.fromJson(stored).matches(expected)) {
          return false;
        }
        data.remove(endpoint);
        await _write(file, data);
        return true;
      });
}
