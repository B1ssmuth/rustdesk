import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_hbb/yesdesk/ssh/models/ssh_profile.dart';
import 'package:flutter_hbb/yesdesk/ssh/services/ssh_transport.dart';
import 'package:flutter_hbb/yesdesk/ssh/sftp/sftp_files.dart';
import 'package:flutter_hbb/yesdesk/ssh/storage/ssh_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

final _env = Platform.environment;
final _port = int.tryParse(_env['YESDESK_SFTP_PORT'] ?? '');
const _timeout = Duration(seconds: 6);

void main() {
  late Directory scratch;
  late LocalFiles local;
  late SshRepository repository;

  setUp(() async {
    scratch = await Directory.systemTemp.createTemp('yesdesk-sftp-');
    local = await LocalFiles.open(scratch.path);
    repository = SshRepository(() async => scratch);
  });
  tearDown(() async => scratch.delete(recursive: true));

  test('local destinations reject traversal and Windows aliases', () async {
    for (final name in [
      '..',
      '.',
      '/etc/passwd',
      r'..\file',
      'a:b',
      'CON.txt',
      'NUL .txt',
      'lpt².txt',
      'trailing.',
      'trailing '
    ]) {
      await expectLater(
          local.child(local.root, name), throwsA(isA<FileOperationError>()));
    }
    expect(await local.child(local.root, 'Файл с пробелом.txt'),
        p.join(local.root, 'Файл с пробелом.txt'));
    expect(() => remoteChild('/home', '../escape'),
        throwsA(isA<FileOperationError>()));
    expect(remoteChild('/home', 'Файл с пробелом.txt'),
        '/home/Файл с пробелом.txt');
  });

  test('local root rejects a link to a directory outside it', () async {
    final outside =
        await Directory.systemTemp.createTemp('yesdesk-sftp-outside-');
    addTearDown(() async => outside.delete(recursive: true));
    final link = await Link(p.join(local.root, 'escape')).create(outside.path);
    await expectLater(
        local.child(link.path, 'file'), throwsA(isA<FileOperationError>()));
  },
      skip: Platform.isWindows
          ? 'Windows link creation depends on runner privileges'
          : false);

  Future<SshRun> connect(
      {bool terminal = false, int? port, void Function(String)? onText}) async {
    final run = SshRun(
      terminal: terminal,
      profile: SshProfile(
          id: 'fixture',
          name: 'Fixture',
          host: '127.0.0.1',
          port: port ?? _port!,
          username: 'sftp-test',
          auth: SshAuth.privateKey,
          timeoutSeconds: _timeout.inSeconds),
      trust: repository,
      prompts: SshPrompts(
        verify: (key, _) async =>
            port != null || key.fingerprint == _env['YESDESK_SFTP_FINGERPRINT'],
        password: (_) async => null,
        privateKey: (_) async =>
            (path: _env['YESDESK_SFTP_KEY']!, passphrase: null),
        challenge: (_, __) async => null,
      ),
      onPhase: (_) {},
      onText: onText ?? (_) {},
      size: () => (columns: 80, rows: 24, width: 0, height: 0),
    );
    addTearDown(run.cancel);
    await run.start();
    expect(run.active, isTrue, reason: '${run.failure}');
    return run;
  }

  Future<void> assertShell(SshRun run, StringBuffer output) async {
    run.write("printf 'SFTP_%s\\n' TERMINAL_OK\n");
    final timer = Stopwatch()..start();
    while (!output.toString().contains('SFTP_TERMINAL_OK')) {
      expect(timer.elapsed, lessThan(_timeout));
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  Future<(SshRun, SftpFiles, String)> workspace() async {
    final run = await connect();
    final client = await run.openSftp();
    addTearDown(client.close);
    final files = SftpFiles(client, _timeout);
    final path =
        remoteChild(await client.absolute('.'), p.basename(local.root));
    await client.mkdir(path);
    return (run, files, path);
  }

  group('Container OpenSSH',
      skip: _port == null ? 'Run scripts/test-yesdesk-sftp-openssh.sh' : false,
      () {
    test('channel close and subsystem rejection leave the terminal connected',
        () async {
      final output = StringBuffer();
      final first = await connect(terminal: true, onText: output.write);
      final other = await connect();
      for (var i = 0; i < 6; i++) {
        final client = await first.openSftp();
        expect(await client.listdir(await client.absolute('.')), isNotEmpty);
        await client.close();
      }
      final parallel = await other.openSftp();
      await parallel.close();
      await assertShell(first, output);
      final disabledOutput = StringBuffer();
      final disabled = await connect(
          terminal: true,
          port: int.parse(_env['YESDESK_SFTP_DISABLED_PORT']!),
          onText: disabledOutput.write);
      await expectLater(
          disabled.openSftp(), throwsA(isA<SSHChannelRequestError>()));
      await assertShell(disabled, disabledOutput);
    });

    test('streams large, empty and Cyrillic files, and confirms overwrite',
        () async {
      final (_, files, directory) = await workspace();
      final first = File(p.join(local.root, 'исходный файл'));
      final writer = await first.open(mode: FileMode.write);
      final chunk =
          Uint8List.fromList(List.generate(64 * 1024, (i) => (i * 31) % 251));
      for (var i = 0; i < 1024; i++) {
        await writer.writeFrom(chunk);
      }
      await writer.close();
      final target = remoteChild(directory, 'файл с пробелами.bin');
      final upload = TransferProgress();
      await files.upload(
          first, target, upload, (_) async => fail('unexpected conflict'));
      expect(upload.bytes, 64 * 1024 * 1024);
      final download = TransferProgress();
      await files.download(target, local, local.root, 'копия.bin', download,
          (_) async => fail('unexpected conflict'));
      expect(download.bytes, upload.bytes);
      final output = await File(p.join(local.root, 'копия.bin')).open();
      try {
        for (var i = 0; i < 1024; i++) {
          expect(await output.read(chunk.length), chunk);
        }
      } finally {
        await output.close();
      }

      final empty = await File(p.join(local.root, 'empty')).create();
      await expectLater(
          files.upload(empty, target, TransferProgress(), (_) async => false),
          throwsA(isA<TransferCancelled>()));
      expect((await files.client.stat(target)).size, upload.bytes);
      await files.upload(empty, target, TransferProgress(), (_) async => true);
      await files.download(target, local, local.root, 'копия.bin',
          TransferProgress(), (_) async => true);
      expect(await File(p.join(local.root, 'копия.bin')).length(), 0);
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('server permissions, rename conflict and nonrecursive deletion',
        () async {
      final (_, files, directory) = await workspace();
      final client = files.client;
      final denied = remoteChild(await client.absolute('.'), 'denied');
      await expectLater(
          client.listdir(denied),
          throwsA(isA<SftpStatusError>()
              .having((e) => e.code, 'code', SftpStatusCode.permissionDenied)));
      final subdirectory = remoteChild(directory, 'каталог');
      await client.mkdir(subdirectory);
      final source =
          await File(p.join(local.root, 'source')).writeAsString('source');
      final a = remoteChild(directory, 'a');
      final b = remoteChild(subdirectory, 'b');
      await files.upload(source, a, TransferProgress(), (_) async => true);
      await files.upload(source, b, TransferProgress(), (_) async => true);
      await expectLater(files.rename(a, b), throwsA(isA<SftpStatusError>()));
      await expectLater(files.delete(subdirectory, SftpFileType.directory),
          throwsA(isA<SftpStatusError>()));
      expect((await client.stat(b)).size, 6);
      await files.delete(b, SftpFileType.regularFile);
      await files.delete(subdirectory, SftpFileType.directory);
      expect((await client.listdir(directory)).map((entry) => entry.filename),
          isNot(contains('каталог')));
    });

    test('detects concurrent UTF-8 edits, preserves mode and rejects binary',
        () async {
      final (_, files, directory) = await workspace();
      final client = files.client;
      final target = remoteChild(directory, 'text');
      final source =
          await File(p.join(local.root, 'source')).writeAsString('Привет');
      await files.upload(source, target, TransferProgress(), (_) async => true);
      await client.setStat(
          target, SftpFileAttrs(mode: const SftpFileMode.value(0x1a0)));
      final original = await files.readText(target);
      expect(original.original, 'Привет');
      await files.saveText(original, 'Пока', TransferProgress());
      expect((await files.readText(target)).original, 'Пока');
      expect((await client.stat(target)).mode!.value & 0x1ff, 0x1a0);
      await expectLater(
          files.saveText(original, 'conflict', TransferProgress()),
          throwsA(isA<FileOperationError>()
              .having((e) => e.problem, 'problem', FileProblem.changed)));
      await source.writeAsBytes([0, 0xff]);
      await files.upload(source, target, TransferProgress(), (_) async => true);
      await expectLater(
          files.readText(target),
          throwsA(isA<FileOperationError>()
              .having((e) => e.problem, 'problem', FileProblem.text)));
    });

    test(
        'cancel cleans staging and disconnect never publishes a partial download',
        () async {
      final (run, files, directory) = await workspace();
      final localSource = File(p.join(local.root, 'large'));
      final handle = await localSource.open(mode: FileMode.write);
      await handle.truncate(32 * 1024 * 1024);
      await handle.close();
      final target = remoteChild(directory, 'large');
      final progress = TransferProgress();
      final cancel = Timer.periodic(const Duration(milliseconds: 1), (timer) {
        if (progress.bytes > 0) {
          progress.cancelled = true;
          timer.cancel();
        }
      });
      addTearDown(cancel.cancel);
      await expectLater(
          files.upload(localSource, target, progress, (_) async => true),
          throwsA(isA<TransferCancelled>()));
      expect((await files.client.listdir(directory)).map((e) => e.filename),
          unorderedEquals(['.', '..']));

      await files.upload(
          localSource, target, TransferProgress(), (_) async => true);
      final receiving = TransferProgress();
      final disconnect =
          Timer.periodic(const Duration(milliseconds: 1), (timer) {
        if (receiving.bytes > 0) {
          run.cancel();
          timer.cancel();
        }
      });
      addTearDown(disconnect.cancel);
      await expectLater(
          files.download(target, local, local.root, 'interrupted', receiving,
              (_) async => true),
          throwsA(isA<SftpAbortError>()));
      expect(await File(p.join(local.root, 'interrupted')).exists(), isFalse);
      expect(receiving.leftover, isNull);
    });
  });
}
