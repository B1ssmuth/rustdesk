import 'dart:convert';
import 'dart:io';

import 'package:flutter_hbb/yesdesk/connections/catalog_codec.dart';
import 'package:flutter_hbb/yesdesk/connections/catalog_view.dart';
import 'package:flutter_hbb/yesdesk/connections/connection_profile.dart';
import 'package:flutter_hbb/yesdesk/connections/connection_repository.dart';
import 'package:flutter_hbb/yesdesk/rdp/rdp_profile.dart';
import 'package:flutter_hbb/yesdesk/rdp/rdp_profile_store.dart';
import 'package:flutter_hbb/yesdesk/ssh/models/ssh_profile.dart';
import 'package:flutter_hbb/yesdesk/ssh/storage/ssh_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

void main() {
  late Directory root;
  late SshRepository ssh;
  late RdpProfileStore rdp;
  late ConnectionRepository repository;
  late List<NativePeer> peers;

  Future<Directory> location(String name) async =>
      Directory('${root.path}/$name');
  ConnectionRepository open([String prefix = '']) => ConnectionRepository(
        ssh: prefix.isEmpty
            ? ssh
            : SshRepository(() => location('${prefix}ssh')),
        rdp: prefix.isEmpty
            ? rdp
            : RdpProfileStore(directory: () => location('${prefix}rdp')),
        nativePeers: () async => prefix.isEmpty ? peers : [],
        directory: () => location('${prefix}catalog'),
      );

  ConnectionProfile profile(ConnectionType type, {String? id, String? folder}) {
    final profileId = id ?? const Uuid().v4();
    final host =
        type == ConnectionType.remoteDesktop ? '123456789' : 'alpha.example';
    final name = 'Backup';
    final options =
        transportOptions(type, profileId, name, host, null, 'ops', {});
    return ConnectionProfile(
      id: profileId,
      name: name,
      host: host,
      username: 'ops',
      options: options,
      folderId: folder,
      tags: ['infra', 'архив'],
    );
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('yesdesk-catalog-test-');
    ssh = SshRepository(() => location('ssh'));
    rdp = RdpProfileStore(directory: () => location('rdp'));
    peers = [];
    repository = open();
  });
  tearDown(() => root.delete(recursive: true));

  test(
      'projects legacy files and favorites without modifying them or repeating rows',
      () async {
    final old = SshProfile(
        id: 'legacy-shared-id',
        name: 'Legacy terminal',
        host: 'old.example',
        username: 'root',
        group: 'Operations',
        favorite: true);
    await ssh.save(old);
    await ssh.addGroup('Empty group');
    await ssh.attachSecret(old, 'vault-reference');
    await rdp.save(RdpProfile(
        id: old.id,
        name: 'Legacy mstsc',
        endpoint: RdpEndpoint.parse('terminal.example', 3389)!));
    final recentAt = DateTime.utc(2025, 12, 15);
    peers = [
      (
        id: '123456789',
        name: 'Recent and favorite',
        username: 'desktop',
        favorite: true,
        recentAt: recentAt
      ),
      (
        id: '123456789',
        name: 'Recent and favorite',
        username: 'desktop',
        favorite: true,
        recentAt: recentAt
      ),
      (
        id: '987654321',
        name: 'Favorite only',
        username: '',
        favorite: true,
        recentAt: null
      ),
    ];
    final sshFile = File('${(await location('ssh')).path}/profiles.json');
    final rdpFile = File('${(await location('rdp')).path}/profiles.json');
    final before = [await sshFile.readAsString(), await rdpFile.readAsString()];
    final catalog = await repository.load();
    expect(catalog.profiles.length, 4);
    expect((await open().load()).profiles.keys, catalog.profiles.keys);
    expect((await sshFile.readAsString()), before.first);
    expect((await rdpFile.readAsString()), before.last);
    final terminal = catalog.profiles.values
        .singleWhere((p) => p.type == ConnectionType.ssh);
    expect(terminal.secretRef, 'vault-reference');
    expect(terminal.favorite, isTrue);
    expect(catalog.folderPath(terminal.folderId), 'Operations');
    expect(catalog.folders.values.map((f) => f.name), contains('Empty group'));
    final recent = catalog.find(
        query: '',
        filter: CatalogFilter.recent,
        sort: CatalogSort.name,
        folderId: null);
    expect(recent.single.lastConnectedAt, recentAt);
    await repository.delete(recent.single.id);
    expect((await open().load()).profiles.length, 3);
    expect(peers, hasLength(3));
  });

  test(
      'creates, edits, favorites, pins, and removes profiles through backing stores',
      () async {
    final original = profile(ConnectionType.sftp);
    await repository.save(original);
    final before = (await open().load()).profiles[original.id]!;
    expect(before.createdAt, isNotNull);
    expect((await ssh.load()).profiles.single.filesOnly, isTrue);
    final edited = decodeProfile({...encodeProfile(before), 'name': 'Changed'});
    await repository.save(edited);
    await repository.setPinned(original.id, true);
    await repository.setFavorite(original.id, true);
    await repository
        .markSshConnected((before.options as SftpOptions).transport.id);
    final after = (await open().load()).profiles[original.id]!;
    expect(after.name, 'Changed');
    expect(after.createdAt, before.createdAt);
    expect(after.updatedAt, isNotNull);
    expect(after.lastConnectedAt, isNotNull);
    expect(after.pinned, isTrue);
    expect((await ssh.load()).profiles.single.favorite, isTrue);
    expect((await ssh.load()).profiles.single.name, 'Changed');
    await repository.delete(original.id);
    expect((await open().load()).profiles, isEmpty);
    expect((await ssh.load()).profiles, isEmpty);
  });

  test('deep folders, search terms, favorite filters and cycle rejection',
      () async {
    final folders = List.generate(25, (_) => const Uuid().v4());
    for (final (index, id) in folders.indexed) {
      await repository.saveFolder(ConnectionFolder(
          id, 'Folder $index', index == 0 ? null : folders[index - 1]));
    }
    final inner = profile(ConnectionType.ssh, folder: folders.last);
    await repository.save(inner);
    await repository.save(profile(ConnectionType.rdp));
    await repository.setFavorite(inner.id, true);
    final catalog = await open().load();
    expect(catalog.ancestors(folders.last), hasLength(25));
    expect(
        catalog
            .find(
                query: 'Архив ALPHA SSH Backup',
                filter: CatalogFilter.favorites,
                sort: CatalogSort.type,
                folderId: folders.first)
            .single
            .id,
        inner.id);
    expect(
        catalog
            .find(
                query: 'архив',
                filter: CatalogFilter.all,
                sort: CatalogSort.type,
                folderId: null,
                type: ConnectionType.rdp)
            .single
            .type,
        ConnectionType.rdp);
    await expectLater(
        repository
            .saveFolder(ConnectionFolder(folders.first, 'Cycle', folders.last)),
        throwsFormatException);
    expect((await open().load()).folders[folders.first]!.parentId, isNull);
  });

  test(
      'versioned export excludes references, trust and SSH comments across all types',
      () async {
    for (final type in ConnectionType.values) {
      await repository.save(profile(type));
    }
    final terminal =
        (await ssh.load()).profiles.singleWhere((p) => !p.filesOnly);
    await ssh.save(SshProfile.fromJson(
        {...terminal.toJson(), 'comment': 'PRIVATE KEY MARKER'}));
    await ssh.attachSecret(terminal, 'vault-secret-id');
    await ssh.remember(
        terminal.endpoint, const SshHostKey('ssh-ed25519', 'trust-marker'));
    final catalog = await repository.load();
    final export = exportCatalog(catalog);
    expect(export, isNot(contains('vault-secret-id')));
    expect(export, isNot(contains('secretRef')));
    expect(export, isNot(contains('PRIVATE KEY MARKER')));
    expect(export, isNot(contains('trust-marker')));
    final data = jsonDecode(export) as Json;
    final first = (data['profiles'] as List)
        .cast<Json>()
        .firstWhere((p) => p['type'] == 'ssh');
    first['secretRef'] = 'injected-reference';
    (first['settings'] as Json)['password'] = 'injected-password';
    (first['settings'] as Json)['comment'] = 'injected-key';
    final destination = open('imported');
    expect(await destination.importProfiles(jsonEncode(data)), 4);
    expect(await open('imported').importProfiles(export), 0);
    final imported = await destination.load();
    expect(imported.profiles.keys, unorderedEquals(catalog.profiles.keys));
    expect(imported.profiles.values.every((p) => p.secretRef == null), isTrue);
    expect(exportCatalog(imported), isNot(contains('injected')));
    final native =
        await File('${(await location('importedssh')).path}/profiles.json')
            .readAsString();
    expect(native, isNot(contains('injected')));
  });

  test('validates bundled folders before any import write', () async {
    final id = const Uuid().v4();
    final corrupted = jsonEncode({
      'format': 'yesdesk-connections',
      'version': 1,
      'folders': [
        {'id': id, 'name': 'Cycle', 'parentId': id}
      ],
      'profiles': [encodeProfile(profile(ConnectionType.ssh))],
    });
    await expectLater(
        repository.importProfiles(corrupted), throwsFormatException);
    expect((await ssh.load()).profiles, isEmpty);
    expect((await repository.load()).folders, isEmpty);
  });

  test(
      'duplicating an SSH profile does not reuse its backing UUID or credential',
      () async {
    final initial = profile(ConnectionType.ssh);
    await repository.save(initial);
    final terminal = (await ssh.load()).profiles.single;
    await ssh.attachSecret(terminal, 'original-vault-reference');
    final copy = decodeProfile({
      ...encodeProfile((await repository.load()).profiles[initial.id]!),
      'id': const Uuid().v4(),
      'name': 'Copy of Backup',
    });
    await repository.save(copy);
    final catalog = await open().load();
    expect(catalog.profiles[copy.id]!.secretRef, isNull);
    expect(catalog.profiles[initial.id]!.secretRef, 'original-vault-reference');
    expect((await ssh.load()).profiles.map((p) => p.id).toSet(), hasLength(2));
  });
  test('legacy RustDesk server parameters stay in the native source', () async {
    const target = '123456789@desk.example:21116?key=legacyServerKey=';
    peers = [
      (
        id: target,
        name: 'Legacy peer',
        username: '',
        favorite: true,
        recentAt: null
      ),
    ];
    final original = (await repository.load()).profiles.values.single;
    expect(original.displayHost, '123456789@desk.example:21116');
    expect(RemoteDesktopOptions.validTarget(target), isFalse);
    expect(RemoteDesktopOptions.validNativeTarget(target), isTrue);
    expect(exportCatalog(await repository.load()),
        isNot(contains('legacyServerKey')));
    await repository.save(decodeProfile({
      ...encodeProfile(original),
      'host': original.displayHost,
      'name': 'Edited peer',
    }));
    final edited = (await open().load()).profiles.values.single;
    expect(edited.id, original.id);
    expect(edited.name, 'Edited peer');
    expect(edited.host, target);
    final local = await File('${(await location('catalog')).path}/catalog.json')
        .readAsString();
    expect(local, isNot(contains('legacyServerKey')));
  });

  test(
      'repeat import completes reserved metadata without creating another backing profile',
      () async {
    final initial = profile(ConnectionType.ssh);
    await repository.save(initial);
    final current = await repository.load();
    final exported = exportCatalog(current);
    final file = File('${(await location('catalog')).path}/catalog.json');
    final state = jsonDecode(await file.readAsString()) as Json;
    final records = state['records'] as Json;
    records[records.keys.single] = {'id': initial.id, 'reserved': true};
    await file.writeAsString(jsonEncode(state));
    expect(await open().importProfiles(exported), 1);
    expect(await open().importProfiles(exported), 0);
    final restored = (await open().load()).profiles.values.single;
    expect(restored.id, initial.id);
    expect(restored.tags, initial.tags);
    expect((await ssh.load()).profiles, hasLength(1));
  });
}
