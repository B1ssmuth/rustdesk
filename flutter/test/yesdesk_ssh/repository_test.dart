import 'dart:io';

import 'package:flutter_hbb/yesdesk/ssh/models/ssh_profile.dart';
import 'package:flutter_hbb/yesdesk/ssh/storage/ssh_repository.dart';
import 'package:flutter_hbb/yesdesk/ssh/storage/ssh_secrets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

void main() {
  late Directory directory;
  late SshRepository repository;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('yesdesk-ssh-repo-');
    repository = SshRepository(() async => directory);
  });
  tearDown(() async => directory.delete(recursive: true));

  test('profiles and empty groups survive reopening and editing', () async {
    final id = const Uuid().v4();
    final first = SshProfile(
      id: id,
      name: 'Build server',
      host: 'SSH.Example.org',
      username: 'admin',
      group: 'Servers',
      favorite: true,
    );
    await repository.addGroup('Empty group');
    await repository.save(first);
    final reopened = SshRepository(() async => directory);
    final initial = await reopened.load();
    expect(initial.groups, unorderedEquals(['Servers', 'Empty group']));
    expect(initial.profiles.single.port, 22);
    expect(initial.profiles.single.endpoint, '[ssh.example.org]:22');
    final edited = SshProfile.fromJson({
      ...initial.profiles.single.toJson(),
      'name': 'Renamed',
      'auth': 'privateKey',
      'palette': 'light',
      'timeoutSeconds': 30,
      'fontSize': 16.5,
    });
    await reopened.save(edited);
    expect((await repository.load()).profiles.single.toJson(), edited.toJson());
    await reopened.delete(id);
    final deleted = await repository.load();
    expect(deleted.profiles, isEmpty);
    expect(deleted.groups, unorderedEquals(['Servers', 'Empty group']));
  });

  test('saved metadata contains a reference only and rejects stale attachment',
      () async {
    final first =
        SshProfile(id: 'test', name: 'Host', host: '::1', username: 'alice');
    final reference = const Uuid().v4();
    await repository.save(first);
    final attached = await repository.attachSecret(first, reference);
    expect(attached.saved, isTrue);
    final raw = await File('${directory.path}/profiles.json').readAsString();
    expect(raw, contains(reference));
    expect(
        raw,
        isNot(contains(
            RegExp(r'"(password|privateKey|passphrase|secret)"\s*:'))));
    final changed = SshProfile.fromJson({...first.toJson(), 'username': 'bob'});
    await repository.save(changed);
    expect((await repository.attachSecret(first, reference)).saved, isFalse);
    expect((await repository.load()).profiles.single.secretRef, isNull);
  });

  test('prevents concurrent trust decisions from overwriting a stored key',
      () async {
    const first = SshHostKey('ssh-ed25519', 'SHA256:first');
    const second = SshHostKey('ssh-ed25519', 'SHA256:second');
    final results = await Future.wait([
      repository.remember('[example.org]:22', first),
      repository.remember('[example.org]:22', second),
    ]);
    expect(results.first, isNull);
    expect(results.last!.matches(first), isTrue);
    expect(
        (await repository.lookup('[example.org]:22'))!.matches(first), isTrue);
    expect(await repository.lookup('[example.org]:2222'), isNull);
  });

  test('validates address formats and test-unique Windows vault entries', () {
    expect(SshProfile.validHost('[2001:db8::5]'), isTrue);
    expect(SshProfile.validHost('2001:db8::5'), isTrue);
    expect(SshProfile.validHost('https://example.org/path'), isFalse);
    expect(SshProfile.validHost('example.org:22'), isFalse);
    const vault = SystemSshSecretStore();
    final id = const Uuid().v4();
    const secret = 'YES Desk vault test UTF-8 пароль 🔑';
    if (vault.canPersist) {
      try {
        expect(vault.write(id, secret), isTrue);
        expect(vault.read(id), secret);
        expect(vault.delete(id), isTrue);
        expect(vault.read(id), isNull);
      } finally {
        vault.delete(id);
      }
    } else {
      expect(vault.write(id, secret), isFalse);
      expect(vault.read(id), isNull);
    }
  });
}
