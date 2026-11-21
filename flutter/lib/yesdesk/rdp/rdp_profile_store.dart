import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'rdp_profile.dart';

class RdpProfileStore {
  RdpProfileStore({Future<Directory> Function()? directory})
      : _directory = directory ?? _defaultDirectory;

  final Future<Directory> Function() _directory;
  Future<void> _pending = Future.value();

  static Future<Directory> _defaultDirectory() async =>
      Directory(p.join((await getApplicationSupportDirectory()).path, 'rdp'));

  Future<List<RdpProfile>> load() => _transaction();

  Future<List<RdpProfile>> save(RdpProfile profile) =>
      _transaction((profiles) => profiles[profile.id] = profile);

  Future<List<RdpProfile>> delete(String id) =>
      _transaction((profiles) => profiles.remove(id));

  Future<List<RdpProfile>> _transaction(
      [void Function(Map<String, RdpProfile>)? update]) {
    final operation = _pending.then((_) async {
      final directory = await _directory();
      await directory.create(recursive: true);
      final lock = await File(p.join(directory.path, 'profiles.lock'))
          .open(mode: FileMode.append);
      try {
        await lock.lock(FileLock.blockingExclusive);
        final file = File(p.join(directory.path, 'profiles.json'));
        final saved = await file.exists()
            ? jsonDecode(await file.readAsString()) as List<dynamic>
            : const [];
        final profiles = <String, RdpProfile>{};
        for (final entry in saved) {
          final profile = RdpProfile.fromJson(entry as Map<String, dynamic>);
          profiles[profile.id] = profile;
        }
        if (update != null) {
          update(profiles);
          final temporary = File('${file.path}.tmp');
          await temporary.writeAsString(
              jsonEncode(profiles.values.map((p) => p.toJson()).toList()),
              flush: true);
          await temporary.rename(file.path);
        }
        return profiles.values.toList();
      } finally {
        await lock.close();
      }
    });
    _pending =
        operation.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return operation;
  }
}
