import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../rdp/rdp_profile_store.dart';
import '../ssh/storage/ssh_repository.dart';
import '../ssh/storage/ssh_secrets.dart';
import 'catalog_codec.dart';
import 'catalog_view.dart';
import 'connection_profile.dart';

typedef NativePeer = ({
  String id,
  String name,
  String username,
  bool favorite,
  DateTime? recentAt,
});

abstract interface class PersonalConnectionsProvider {
  Future<ConnectionCatalog> load();
}

class ConnectionRepository implements PersonalConnectionsProvider {
  ConnectionRepository({
    required this.ssh,
    required this.rdp,
    required this.nativePeers,
    this.secrets = const SystemSshSecretStore(),
    Future<Directory> Function()? directory,
  }) : _directory = directory ?? _defaultDirectory;

  final SshRepository ssh;
  final RdpProfileStore rdp;
  final Future<List<NativePeer>> Function() nativePeers;
  final SshSecretStore secrets;
  final Future<Directory> Function() _directory;
  Future<void> _pending = Future.value();

  static Future<Directory> _defaultDirectory() async => Directory(
      p.join((await getApplicationSupportDirectory()).path, 'connections'));

  Future<T> _transaction<T>(Future<T> Function(_CatalogFile) operation) {
    final result = _pending.then((_) async {
      final directory = await _directory();
      await directory.create(recursive: true);
      final lock = await File(p.join(directory.path, 'catalog.lock'))
          .open(mode: FileMode.append);
      try {
        await lock.lock(FileLock.blockingExclusive);
        final file = File(p.join(directory.path, 'catalog.json'));
        final data = await file.exists()
            ? jsonDecode(await file.readAsString()) as Json
            : <String, dynamic>{'version': 1};
        if (data['version'] != 1) {
          throw const FormatException('Unsupported local catalog version');
        }
        return await operation(_CatalogFile(file, data));
      } finally {
        await lock.close();
      }
    });
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  @override
  Future<ConnectionCatalog> load() => _transaction(_read);

  Future<ConnectionCatalog> _read(_CatalogFile state) async {
    final sshData = await ssh.load();
    final rdpData = await rdp.load();
    final peers = {
      for (final peer in await nativePeers()) _peerIdentity(peer.id): peer,
    };
    final folders =
        state.folders.values.cast<Json>().map(decodeFolder).toList();
    final groups = {
      ...sshData.groups,
      ...sshData.profiles
          .map((profile) => profile.group)
          .where((group) => group.isNotEmpty),
    };
    for (final group in groups.where((name) => name.isNotEmpty)) {
      final id = sourceUuid('ssh-group', group);
      if (!state.folders.containsKey(id)) {
        folders.add(ConnectionFolder(id, group, null));
      }
    }
    final folderIds = folders.map((f) => f.id).toSet();

    ConnectionProfile project({
      required String key,
      required String name,
      required String host,
      required String username,
      required TransportOptions options,
      int? port,
      String? legacyFolder,
      bool favorite = false,
      DateTime? recentAt,
      bool native = false,
    }) {
      final meta = state.records[key] as Json? ?? {};
      final folder =
          meta.containsKey('folderId') ? meta['folderId'] : legacyFolder;
      final latest = readDate(meta['lastConnectedAt']);
      return ConnectionProfile(
        id: meta['id'] as String? ?? sourceUuid('legacy', key),
        name: name,
        host: host,
        username: username,
        options: options,
        port: port,
        folderId: folderIds.contains(folder) ? folder as String : null,
        tags: (meta['tags'] as List? ?? []).cast<String>(),
        favorite: meta['favorite'] as bool? ?? favorite,
        pinned: meta['pinned'] as bool? ?? false,
        createdAt: readDate(meta['createdAt']),
        updatedAt: readDate(meta['updatedAt']),
        lastConnectedAt:
            latest != null && (recentAt == null || latest.isAfter(recentAt))
                ? latest
                : recentAt,
        nativePeer: native,
      );
    }

    final profiles = <ConnectionProfile>[
      for (final profile in sshData.profiles)
        project(
          key: 'ssh:${profile.id}',
          name: profile.name,
          host: profile.host,
          username: profile.username,
          port: profile.port,
          options: profile.filesOnly
              ? SftpOptions(profile)
              : TerminalOptions(profile),
          legacyFolder: profile.group.isEmpty
              ? null
              : sourceUuid('ssh-group', profile.group),
          favorite: profile.favorite,
        ),
      for (final profile in rdpData)
        project(
          key: 'rdp:${profile.id}',
          name: profile.name,
          host: profile.endpoint.host,
          username: profile.username,
          port: profile.endpoint.port,
          options: RdpOptions(profile),
        ),
    ];
    final catalogPeers = <String>{};
    for (final entry in state.remote.entries) {
      final profile = decodeProfile(entry.value as Json);
      final source = state.records[entry.key] as Json?;
      final peerId = source?['nativeTarget'] as String?;
      final lookup = peerId ?? _peerIdentity(profile.host);
      catalogPeers.add(lookup);
      final peer = peers[lookup];
      profiles.add(project(
        key: entry.key,
        name: profile.name,
        host: profile.host,
        username: profile.username,
        options: profile.options,
        recentAt: peer?.recentAt,
        native: peerId != null,
      ));
    }
    for (final entry in peers.entries) {
      final identity = entry.key;
      final peer = entry.value;
      if (!catalogPeers.add(identity) || state.hidden.contains(identity)) {
        continue;
      }
      profiles.add(project(
        key: 'peer:$identity',
        name: peer.name,
        host: peer.id,
        username: peer.username,
        options: const RemoteDesktopOptions(),
        favorite: peer.favorite,
        recentAt: peer.recentAt,
        native: true,
      ));
    }
    return ConnectionCatalog(profiles, folders);
  }

  String _peerIdentity(String target) => sourceUuid('peer-target', target);

  String _key(ConnectionProfile profile, _CatalogFile state) =>
      switch (profile.options) {
        SshConnectionOptions(:final transport) => 'ssh:${transport.id}',
        RdpOptions(:final transport) => 'rdp:${transport.id}',
        RemoteDesktopOptions() =>
          state.remote.containsKey('remote:${profile.id}')
              ? 'remote:${profile.id}'
              : 'peer:${_peerIdentity(profile.host)}',
      };

  Future<void> save(ConnectionProfile requested, {bool clearSecret = false}) =>
      _transaction((state) async {
        final catalog = await _read(state);
        await _save(state, catalog, requested, clearSecret: clearSecret);
      });

  Future<void> _save(
    _CatalogFile state,
    ConnectionCatalog catalog,
    ConnectionProfile requested, {
    bool clearSecret = false,
  }) async {
    final old = catalog.profiles[requested.id];
    if (old != null && old.type != requested.type) {
      throw const FormatException('Cannot change connection type');
    }
    final safe = decodeProfile(encodeProfile(requested));
    catalog.ancestors(safe.folderId);
    final now = DateTime.now().toUtc();
    late final String key;
    String? removedSecret;
    String? nativeTarget;
    switch (safe.type) {
      case ConnectionType.ssh:
      case ConnectionType.sftp:
        final previous = (old?.options as SshConnectionOptions?)?.transport;
        final backingId = previous?.id ?? sourceUuid(safe.type.name, safe.id);
        final transport = transportOptions(
          safe.type,
          backingId,
          safe.name,
          safe.host,
          safe.port,
          safe.username,
          {
            ...transportSettings(safe.options),
            'comment': previous?.comment ?? ''
          },
          group: previous?.group ?? '',
          favorite: safe.favorite,
        ) as SshConnectionOptions;
        key = 'ssh:$backingId';
        await _reserve(state, key, safe.id);
        removedSecret =
            await ssh.save(transport.transport, clearSecret: clearSecret);
      case ConnectionType.rdp:
        final previous = (old?.options as RdpOptions?)?.transport;
        final transport = transportOptions(
          safe.type,
          previous?.id ?? sourceUuid('rdp', safe.id),
          safe.name,
          safe.host,
          safe.port,
          safe.username,
          transportSettings(safe.options),
        ) as RdpOptions;
        key = 'rdp:${transport.transport.id}';
        await _reserve(state, key, safe.id);
        await rdp.save(transport.transport);
      case ConnectionType.remoteDesktop:
        key = 'remote:${safe.id}';
        if (old?.nativePeer == true) {
          nativeTarget =
              (state.records[key] as Json?)?['nativeTarget'] as String? ??
                  _peerIdentity(old!.host);
          state.records.remove('peer:$nativeTarget');
        }
        state.remote[key] = encodeProfile(safe);
    }
    state.records[key] = {
      'id': safe.id,
      'folderId': safe.folderId,
      'tags': safe.tags.toList(),
      if (safe.type != ConnectionType.ssh && safe.type != ConnectionType.sftp)
        'favorite': safe.favorite,
      'pinned': safe.pinned,
      'createdAt': (old?.createdAt ?? safe.createdAt ?? now).toIso8601String(),
      'updatedAt': now.toIso8601String(),
      'lastConnectedAt':
          (old?.lastConnectedAt ?? safe.lastConnectedAt)?.toIso8601String(),
      if (nativeTarget != null) 'nativeTarget': nativeTarget,
    };
    await state.write();
    _forget(removedSecret);
  }

  Future<void> _reserve(_CatalogFile state, String key, String id) async {
    final record =
        state.records.putIfAbsent(key, () => <String, dynamic>{}) as Json;
    if (record['id'] == id) return;
    record['id'] = id;
    await state.write();
  }

  Future<void> setFavorite(String id, bool favorite) =>
      _updateMetadata(id, (profile, record) async {
        if (profile.options case SshConnectionOptions(:final transport)) {
          await ssh.setFavorite(transport.id, favorite);
        } else {
          record['favorite'] = favorite;
        }
        record['updatedAt'] = DateTime.now().toUtc().toIso8601String();
      });

  Future<void> setPinned(String id, bool pinned) =>
      _updateMetadata(id, (_, record) async {
        record['pinned'] = pinned;
        record['updatedAt'] = DateTime.now().toUtc().toIso8601String();
      });

  Future<void> _updateMetadata(
    String id,
    Future<void> Function(ConnectionProfile, Json) update,
  ) =>
      _transaction((state) async {
        final profile = (await _read(state)).profiles[id];
        if (profile == null) return;
        final key = _key(profile, state);
        final record =
            state.records.putIfAbsent(key, () => <String, dynamic>{}) as Json;
        await update(profile, record);
        await state.write();
      });

  Future<void> markConnected(String id) =>
      _updateMetadata(id, (_, record) async {
        record['lastConnectedAt'] = DateTime.now().toUtc().toIso8601String();
      });

  Future<void> markSshConnected(String backingId) =>
      _markTransportUsed('ssh:$backingId');

  Future<void> markRdpLaunched(String backingId) =>
      _markTransportUsed('rdp:$backingId');

  Future<void> _markTransportUsed(String key) => _transaction((state) async {
        final record =
            state.records.putIfAbsent(key, () => <String, dynamic>{}) as Json;
        record['lastConnectedAt'] = DateTime.now().toUtc().toIso8601String();
        await state.write();
      });

  Future<void> delete(String id) => _transaction((state) async {
        final catalog = await _read(state);
        final profile = catalog.profiles[id];
        if (profile == null) return;
        final key = _key(profile, state);
        String? removedSecret;
        switch (profile.options) {
          case SshConnectionOptions(:final transport):
            removedSecret = await ssh.delete(transport.id);
          case RdpOptions(:final transport):
            await rdp.delete(transport.id);
          case RemoteDesktopOptions():
            final source =
                (state.records[key] as Json?)?['nativeTarget'] as String?;
            state.hidden.add(source ?? _peerIdentity(profile.host));
            state.hidden.add(_peerIdentity(profile.host));
            state.remote.remove(key);
        }
        state.records.remove(key);
        await state.write();
        _forget(removedSecret);
      });

  void _forget(String? reference) {
    if (reference != null && !secrets.delete(reference)) {
      throw const FileSystemException('Could not remove credential from vault');
    }
  }

  Future<void> saveFolder(ConnectionFolder folder) =>
      _transaction((state) async {
        final catalog = await _read(state);
        final validated = decodeFolder(encodeFolder(folder));
        ConnectionCatalog(catalog.profiles.values, [
          ...catalog.folders.values.where((f) => f.id != folder.id),
          validated,
        ]);
        state.folders[folder.id] = encodeFolder(validated);
        await state.write();
      });

  Future<int> importProfiles(String text) async {
    final incoming = parseCatalog(text);
    return _transaction((state) async {
      var catalog = await _read(state);
      final additions = incoming.folders.values
          .where((folder) => !catalog.folders.containsKey(folder.id))
          .toList();
      ConnectionCatalog(
          catalog.profiles.values, [...catalog.folders.values, ...additions]);
      for (final folder in additions) {
        state.folders[folder.id] = encodeFolder(folder);
      }
      if (additions.isNotEmpty) await state.write();

      var count = 0;
      catalog = await _read(state);
      for (final profile in incoming.profiles.values) {
        if (catalog.profiles.containsKey(profile.id)) continue;
        // Persist each completed profile. A retry uses the same native key.
        await _save(state, catalog, profile);
        count++;
      }
      return count;
    });
  }
}

class _CatalogFile {
  _CatalogFile(this.file, this.data)
      : records =
            data.putIfAbsent('records', () => <String, dynamic>{}) as Json,
        folders =
            data.putIfAbsent('folders', () => <String, dynamic>{}) as Json,
        remote = data.putIfAbsent('remote', () => <String, dynamic>{}) as Json,
        hidden = (data['hidden'] as List? ?? []).cast<String>().toSet();

  final File file;
  final Json data;
  final Json records;
  final Json folders;
  final Json remote;
  final Set<String> hidden;

  Future<void> write() async {
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
        jsonEncode({...data, 'hidden': hidden.toList()}),
        flush: true);
    await temporary.rename(file.path);
  }
}
