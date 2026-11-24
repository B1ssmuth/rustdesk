import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../../theme.dart';
import '../../widgets.dart';
import '../services/ssh_transport.dart';
import '../widgets/ssh_dialogs.dart';
import '../widgets/ssh_strings.dart';
import 'sftp_files.dart';

class SftpExplorer extends StatefulWidget {
  const SftpExplorer({
    super.key,
    required this.run,
    required this.labels,
    required this.twoPanes,
    required this.visible,
  });
  final SshRun run;
  final SshStrings labels;
  final bool twoPanes;
  final bool visible;

  @override
  State<SftpExplorer> createState() => _SftpExplorerState();
}

enum _Order { name, size, modified }

enum _Action { download, edit, rename, delete, properties }

enum _JobState { waiting, running, done, cancelled, failed }

class _Job {
  _Job(this.title, this.operation);
  final String title;
  final Future<void> Function(TransferProgress) operation;
  final progress = TransferProgress();
  _JobState state = _JobState.waiting;
  Object? error;
}

class _SftpExplorerState extends State<SftpExplorer> {
  SshStrings get l => widget.labels;
  final _path = TextEditingController();
  final _search = TextEditingController();
  final _selected = <String>{};
  final _localSelected = <String>{};
  final _jobs = <_Job>[];
  SftpFiles? _files;
  LocalFiles? _local;
  String? _directory;
  List<SftpName> _entries = [];
  List<FileSystemEntity> _localEntries = [];
  _Order _order = _Order.name;
  bool _ascending = true;
  bool _opening = true;
  bool _busy = false;
  bool _localBusy = false;
  bool _working = false;
  bool _dragging = false;
  Object? _error;
  Timer? _ticker;
  late Completer<void> _channelEnded;
  final _disposed = Completer<void>();

  @override
  void initState() {
    super.initState();
    unawaited(_connect());
    unawaited(widget.run.done.then((_) {
      if (mounted) _channelFailed(SftpAbortError('SSH connection closed'));
    }));
  }

  void _channelFailed(Object error) {
    if (!mounted) return;
    setState(() {
      if (!_channelEnded.isCompleted) _channelEnded.complete();
      _files?.client.close().ignore();
      _files = null;
      _error = error;
      for (final job in _jobs.where((job) => job.state == _JobState.waiting)) {
        job.state = _JobState.failed;
        job.error = error;
      }
    });
  }

  @override
  void dispose() {
    _disposed.complete();
    _ticker?.cancel();
    _closeChannel();
    _path.dispose();
    _search.dispose();
    super.dispose();
  }

  void _closeChannel() {
    if (!_channelEnded.isCompleted) _channelEnded.complete();
    for (final job in _jobs) {
      if (!job.progress.publishing) job.progress.cancelled = true;
      if (job.state == _JobState.waiting) job.state = _JobState.cancelled;
    }
    _files?.client.close().ignore();
    _files = null;
  }

  Future<void> _connect() async {
    final channelEnded = _channelEnded = Completer<void>();
    setState(() {
      _opening = true;
      _error = null;
    });
    SftpFiles? files;
    try {
      final client = await widget.run.openSftp();
      files = SftpFiles(
          client, Duration(seconds: widget.run.profile.timeoutSeconds));
      if (!mounted || channelEnded.isCompleted || widget.run.ended) {
        client.close().ignore();
        return;
      }
      _files = files;
      final directory = await files.request(client.absolute('.'));
      final entries = await files.request(client.listdir(directory));
      if (!mounted || channelEnded.isCompleted || widget.run.ended) {
        client.close().ignore();
        return;
      }
      setState(() {
        _setDirectory(directory, entries);
      });
    } catch (error) {
      files?.client.close().ignore();
      if (mounted) _channelFailed(error);
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  void _setDirectory(String path, List<SftpName> entries) {
    _loadedPath = path;
    _path.text = path;
    _entries = entries.where((entry) {
      final name = entry.filename;
      return name != '.' &&
          name != '..' &&
          name.isNotEmpty &&
          !name.contains('/') &&
          !name.contains('\x00');
    }).toList();
    _selected.clear();
  }

  Future<void> _navigate(String path) async {
    final files = _files;
    if (files == null || _busy || path.contains('\x00') || path.isEmpty) return;
    await _remote(() async {
      final canonical = await files.request(files.client.absolute(path));
      final entries = await files.request(files.client.listdir(canonical));
      if (mounted && identical(files, _files)) {
        setState(() => _setDirectory(canonical, entries));
      }
    });
  }

  Future<void> _remote(Future<void> Function() operation) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await operation();
    } catch (error) {
      if (error is SftpAbortError || error is TimeoutException) {
        _channelFailed(error);
      }
      _notice(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _message(Object error) => switch (error) {
        FileOperationError(problem: FileProblem.invalidName) => l.text(
            'Invalid or unsafe path', 'Недопустимый или небезопасный путь'),
        FileOperationError(problem: FileProblem.alreadyExists) => l.text(
            'An item with this name already exists.',
            'Элемент с таким именем уже существует.'),
        FileOperationError(problem: FileProblem.changed) => l.text(
            'File or directory changed. Refresh and try again.',
            'Файл или каталог изменился. Обновите список и повторите.'),
        FileOperationError(problem: FileProblem.unsafeType) =>
          l.text('Unsupported file type', 'Неподдерживаемый тип файла'),
        FileOperationError(problem: FileProblem.noAtomicReplace) => l.text(
            'The server cannot replace this file atomically.',
            'Сервер не поддерживает атомарную замену файла.'),
        FileOperationError(problem: FileProblem.metadata) => l.text(
            'Could not retain file ownership or permissions.',
            'Не удалось сохранить владельца или права файла.'),
        FileOperationError(problem: FileProblem.incomplete) => l.text(
            'Transfer size did not match',
            'Размер переданных данных не совпал'),
        FileOperationError(problem: FileProblem.text) => l.text(
            'Only UTF-8 text up to 512 KiB can be edited.',
            'Можно редактировать только текст UTF-8 до 512 КиБ.'),
        SftpStatusError(code: SftpStatusCode.permissionDenied) =>
          l.text('Permission denied', 'Доступ запрещён'),
        SftpStatusError(code: SftpStatusCode.noSuchFile) => l.text(
            'File or directory no longer exists',
            'Файл или каталог больше не существует'),
        SftpStatusError(code: SftpStatusCode.failure) => l.text(
            'Server refused the operation. Check for a name conflict or a nonempty directory.',
            'Сервер отклонил операцию. Проверьте конфликт имени или наличие файлов в каталоге.'),
        SftpAbortError() || TimeoutException() => l.text(
            'SFTP channel closed or timed out',
            'Канал SFTP закрыт или истекло время ожидания'),
        FileSystemException() =>
          l.text('Local filesystem error', 'Ошибка локальной файловой системы'),
        _ => l.text('SFTP operation failed', 'Ошибка операции SFTP'),
      };

  void _notice(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(_message(error))),
    );
  }

  Future<void> _localAction(Future<void> Function() operation) async {
    if (_localBusy) return;
    setState(() => _localBusy = true);
    try {
      await operation();
    } catch (error) {
      _notice(error);
    } finally {
      if (mounted) setState(() => _localBusy = false);
    }
  }

  Future<LocalFiles?> _chooseLocal() async {
    final path = await FilePicker.platform.getDirectoryPath();
    if (!mounted || path == null) return null;
    return LocalFiles.open(path);
  }

  Future<void> _localNavigate(LocalFiles local, String path) async {
    final canonical = await local.directory(path);
    final entries =
        await Directory(canonical).list(followLinks: false).toList();
    entries.sort((a, b) {
      if ((a is Directory) != (b is Directory)) return a is Directory ? -1 : 1;
      return a.path.toLowerCase().compareTo(b.path.toLowerCase());
    });
    if (!mounted) return;
    setState(() {
      _local = local;
      _directory = canonical;
      _localEntries = entries;
      _localSelected.clear();
    });
  }

  Future<bool> _replace(String path) {
    if (!mounted || _channelEnded.isCompleted) return Future.value(false);
    return sshConfirm(
        context,
        l,
        l.text('Replace existing file?', 'Заменить существующий файл?'),
        l.text('Replace', 'Заменить'),
        content: SelectableText(path),
        ended: Future.any(
            [_channelEnded.future, widget.run.done, _disposed.future]));
  }

  void _enqueue(
      String title, Future<void> Function(TransferProgress) operation) {
    if (!mounted) return;
    setState(() => _jobs.add(_Job(title, operation)));
    if (!_working) unawaited(_drain());
  }

  Future<void> _drain() async {
    _working = true;
    _ticker = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (mounted) setState(() {});
    });
    try {
      while (mounted) {
        final job =
            _jobs.where((job) => job.state == _JobState.waiting).firstOrNull;
        if (job == null) break;
        setState(() {
          job.state = _JobState.running;
          job.progress.clock.start();
        });
        try {
          await job.operation(job.progress);
          job.state = _JobState.done;
        } on TransferCancelled {
          job.state = _JobState.cancelled;
        } catch (error) {
          job.state = _JobState.failed;
          job.error = error;
          if (error is SftpAbortError || error is TimeoutException) {
            _channelFailed(error);
          }
        } finally {
          job.progress.clock.stop();
          if (mounted) setState(() {});
        }
      }
    } finally {
      _ticker?.cancel();
      _working = false;
    }
    if (!mounted) return;
    await _navigate(_loadedPath);
    final local = _local;
    final directory = _directory;
    if (local != null && directory != null && mounted) {
      await _localAction(() => _localNavigate(local, directory));
    }
  }

  void _uploadPaths(Iterable<String> paths, SftpFiles files, String destination,
      {LocalFiles? local}) {
    if (!mounted || !identical(files, _files)) return;
    for (final path in paths) {
      final name = p.basename(path);
      _enqueue('↑ $name', (progress) async {
        final checked =
            local == null ? path : await local.child(p.dirname(path), name);
        await files.upload(
            File(checked), remoteChild(destination, name), progress, _replace);
      });
    }
  }

  Future<void> _pickUpload() async {
    final files = _files;
    final destination = _loadedPath;
    if (files == null) return;
    try {
      final picked = await FilePicker.platform.pickFiles(allowMultiple: true);
      if (picked != null) {
        _uploadPaths(picked.paths.whereType<String>(), files, destination);
      }
    } catch (error) {
      _notice(error);
    }
  }

  Future<void> _download(Iterable<SftpName> entries) async {
    final files = _files;
    final sources = entries
        .where((entry) => entry.attr.isFile)
        .map((entry) =>
            (remoteChild(_loadedPath, entry.filename), entry.filename))
        .toList();
    if (files == null || sources.isEmpty) return;
    try {
      final local = _local ?? (widget.twoPanes ? null : await _chooseLocal());
      if (local == null || !mounted || !identical(files, _files)) return;
      final folder = widget.twoPanes ? _directory! : local.root;
      for (final (source, name) in sources) {
        _enqueue(
            '↓ $name',
            (progress) => files.download(
                source, local, folder, name, progress, _replace));
      }
    } catch (error) {
      _notice(error);
    }
  }

  Future<void> _mkdir() async {
    final files = _files;
    final parent = _loadedPath;
    if (files == null) return;
    final name = await sshTextDialog(
        context, l, l.text('New directory', 'Новый каталог'));
    if (!mounted || name == null || !identical(files, _files)) return;
    await _remote(
        () => files.request(files.client.mkdir(remoteChild(parent, name))));
    if (mounted && _loadedPath == parent) await _navigate(parent);
  }

  Future<void> _createFile() async {
    final files = _files;
    final parent = _loadedPath;
    if (files == null) return;
    final name =
        await sshTextDialog(context, l, l.text('New file', 'Новый файл'));
    if (!mounted || name == null || !identical(files, _files)) return;
    String? path;
    await _remote(() async {
      path = await files.createEmptyFile(parent, name);
    });
    if (!mounted || !identical(files, _files) || path == null) return;
    if (_loadedPath == parent) await _navigate(parent);
    if (!mounted || !identical(files, _files)) return;
    final edit = await sshConfirm(
        context,
        l,
        l.text('Open the new file in the text editor?',
            'Открыть новый файл в текстовом редакторе?'),
        l.text('Open', 'Открыть'),
        ended: Future.any([_channelEnded.future, widget.run.done]));
    if (!mounted || !edit || !identical(files, _files)) return;
    await _editText(files, path!, parent);
  }

  Future<void> _editText(SftpFiles files, String path, String parent) async {
    await _remote(() async {
      final original = await files.readText(path);
      if (!mounted || !identical(files, _files)) return;
      await sshDialog<void>(
          context,
          (_) => _TextEditor(
                files: files,
                original: original,
                labels: l,
                message: _message,
              ));
    });
    if (mounted && identical(files, _files) && _loadedPath == parent) {
      await _navigate(parent);
    }
  }

  Future<void> _delete(Iterable<SftpName> entries) async {
    final files = _files;
    final parent = _loadedPath;
    final targets = entries.toList();
    if (files == null || targets.isEmpty) return;
    final approved = await sshConfirm(
        context,
        l,
        l.text('Permanently delete selected items?',
            'Удалить выбранные элементы безвозвратно?'),
        l.delete,
        content: SizedBox(
            width: 420,
            height: 150,
            child: ListView(
                children: [for (final entry in targets) Text(entry.filename)])),
        ended: Future.any([_channelEnded.future, widget.run.done]));
    if (!mounted || !approved || !identical(files, _files)) return;
    await _remote(() async {
      for (final entry in targets) {
        await files.delete(
            remoteChild(parent, entry.filename), entry.attr.type);
      }
    });
    if (mounted && _loadedPath == parent) await _navigate(parent);
  }

  Future<void> _act(_Action action, SftpName entry) async {
    final files = _files;
    if (files == null) return;
    final parent = _loadedPath;
    final path = remoteChild(parent, entry.filename);
    switch (action) {
      case _Action.download:
        await _download([entry]);
      case _Action.delete:
        await _delete([entry]);
      case _Action.rename:
        final name = await sshTextDialog(
            context, l, l.text('Rename', 'Переименовать'),
            initialValue: entry.filename);
        if (!mounted ||
            name == null ||
            name == entry.filename ||
            !identical(files, _files)) return;
        await _remote(() => files.rename(path, remoteChild(parent, name)));
        if (mounted && _loadedPath == parent) await _navigate(parent);
      case _Action.properties:
        await _remote(() async {
          final attrs =
              await files.request(files.client.stat(path, followLink: false));
          if (!mounted) return;
          final mode = attrs.mode;
          await sshDialog<void>(
              context,
              (context) => AlertDialog(
                    title: Text(l.text('Properties', 'Свойства')),
                    content: SelectableText(
                      '$path\n'
                      '${l.text('Size', 'Размер')}  ${attrs.size ?? '—'}\n'
                      '${l.text('Modified', 'Изменён')}  ${_date(attrs.modifyTime)}\n'
                      '${l.text('Permissions', 'Права')}  ${mode == null ? '—' : (mode.value & 0xfff).toRadixString(8).padLeft(4, '0')}\n'
                      'UID  ${attrs.userID ?? '—'}   GID  ${attrs.groupID ?? '—'}',
                    ),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: Text(l.cancel))
                    ],
                  ));
        });
      case _Action.edit:
        await _editText(files, path, parent);
    }
  }

  String _date(int? seconds) {
    if (seconds == null) return '—';
    final date = DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
    final year = date.year;
    String pad(int number) => number.toString().padLeft(2, '0');
    return '$year-${pad(date.month)}-${pad(date.day)} ${pad(date.hour)}:${pad(date.minute)}';
  }

  List<SftpName> get _visible {
    final query = _search.text.toLowerCase();
    return _entries
        .where((entry) => entry.filename.toLowerCase().contains(query))
        .toList()
      ..sort((a, b) {
        if (a.attr.isDirectory != b.attr.isDirectory) {
          return a.attr.isDirectory ? -1 : 1;
        }
        final name =
            a.filename.toLowerCase().compareTo(b.filename.toLowerCase());
        final order = switch (_order) {
          _Order.name => name,
          _Order.size => (a.attr.size ?? -1).compareTo(b.attr.size ?? -1),
          _Order.modified =>
            (a.attr.modifyTime ?? -1).compareTo(b.attr.modifyTime ?? -1),
        };
        return (order == 0 ? name : order) * (_ascending ? 1 : -1);
      });
  }

  Iterable<SftpName> get _selection =>
      _entries.where((entry) => _selected.contains(entry.filename));

  String _label(_Action action) => switch (action) {
        _Action.download => l.text('Download', 'Скачать'),
        _Action.edit => l.text('Edit text', 'Редактировать текст'),
        _Action.rename => l.text('Rename', 'Переименовать'),
        _Action.delete => l.delete,
        _Action.properties => l.text('Properties', 'Свойства'),
      };

  List<PopupMenuEntry<_Action>> _menu(SftpName entry) => [
        for (final action in _Action.values)
          if ((action != _Action.edit && action != _Action.download) ||
              (entry.attr.isFile &&
                  (action != _Action.download ||
                      !widget.twoPanes ||
                      _local != null)))
            PopupMenuItem(value: action, child: Text(_label(action))),
      ];

  Widget _remotePane(SftpFiles files) {
    final visible = _visible;
    return DropTarget(
      enable:
          widget.visible && !_busy && (ModalRoute.isCurrentOf(context) ?? true),
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: (details) {
        setState(() => _dragging = false);
        _uploadPaths(
            details.files.map((file) => file.path), files, _loadedPath);
      },
      child: DragTarget<List<String>>(
        onWillAcceptWithDetails: (_) => _local != null && !_busy,
        onAcceptWithDetails: (details) =>
            _uploadPaths(details.data, files, _loadedPath, local: _local),
        builder: (context, candidates, _) => Material(
          color: _dragging || candidates.isNotEmpty
              ? YesDeskColors.of(context).selected
              : YesDeskColors.of(context).surface,
          child: Column(
            children: [
              Row(children: [
                YesDeskIconButton(
                    label: l.text('Parent directory', 'Родительский каталог'),
                    icon: Icons.arrow_upward,
                    onPressed: _busy
                        ? null
                        : () => _navigate(p.posix.dirname(_loadedPath))),
                Expanded(
                    child: TextField(
                  controller: _path,
                  readOnly: _busy,
                  decoration: InputDecoration(
                      labelText: l.text('Remote path', 'Путь на сервере')),
                  onSubmitted: (value) {
                    // The field can contain an unsubmitted edit. Resolve relative paths against
                    // the directory whose entries are currently displayed.
                    final path = value.startsWith('/')
                        ? value
                        : p.posix.join(_loadedPath, value);
                    _path.text = _loadedPath;
                    unawaited(_navigate(path));
                  },
                )),
                YesDeskIconButton(
                    label: l.text('Refresh (F5)', 'Обновить (F5)'),
                    icon: Icons.refresh,
                    onPressed: _busy ? null : () => _navigate(_loadedPath)),
              ]),
              Row(children: [
                Expanded(
                    child: TextField(
                  controller: _search,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    labelText: l.text('Search files', 'Поиск файлов'),
                    prefixIcon: const Icon(Icons.search, size: 18),
                  ),
                )),
                DropdownButton<_Order>(
                  value: _order,
                  onChanged: (value) => setState(() => _order = value!),
                  items: [
                    DropdownMenuItem(
                        value: _Order.name, child: Text(l.text('Name', 'Имя'))),
                    DropdownMenuItem(
                        value: _Order.size,
                        child: Text(l.text('Size', 'Размер'))),
                    DropdownMenuItem(
                        value: _Order.modified,
                        child: Text(l.text('Modified', 'Изменён'))),
                  ],
                ),
                YesDeskIconButton(
                    label: l.text('Reverse sort', 'Обратная сортировка'),
                    icon:
                        _ascending ? Icons.arrow_upward : Icons.arrow_downward,
                    onPressed: () => setState(() => _ascending = !_ascending)),
              ]),
              Wrap(children: [
                YesDeskIconButton(
                    label: l.text('New directory', 'Новый каталог'),
                    icon: Icons.create_new_folder_outlined,
                    onPressed: _busy ? null : _mkdir),
                YesDeskIconButton(
                    label: l.text('New file', 'Новый файл'),
                    icon: Icons.note_add_outlined,
                    onPressed: _busy ? null : _createFile),
                YesDeskIconButton(
                    label: l.text('Upload files', 'Загрузить файлы'),
                    icon: Icons.upload,
                    onPressed: _busy ? null : _pickUpload),
                YesDeskIconButton(
                    label: _label(_Action.download),
                    icon: Icons.download,
                    onPressed: !_selection.any((entry) => entry.attr.isFile) ||
                            (widget.twoPanes && _local == null) ||
                            _busy
                        ? null
                        : () => _download(_selection)),
                YesDeskIconButton(
                    label: l.delete,
                    icon: Icons.delete_outline,
                    onPressed: _selected.isEmpty || _busy
                        ? null
                        : () => _delete(_selection)),
                YesDeskIconButton(
                    label: l.text('Close SFTP channel', 'Закрыть канал SFTP'),
                    icon: Icons.link_off,
                    onPressed: _working || _busy
                        ? null
                        : () => setState(_closeChannel)),
              ]),
              if (_busy) const LinearProgressIndicator(),
              Expanded(
                child: CallbackShortcuts(
                  bindings: _busy
                      ? const {}
                      : {
                          const SingleActivator(LogicalKeyboardKey.f5): () =>
                              _navigate(_loadedPath),
                          const SingleActivator(LogicalKeyboardKey.delete):
                              () => _delete(_selection),
                          const SingleActivator(LogicalKeyboardKey.f2): () {
                            if (_selection.length == 1) {
                              unawaited(_act(_Action.rename, _selection.first));
                            }
                          },
                          const SingleActivator(LogicalKeyboardKey.keyA,
                                  control: true):
                              () => setState(() => _selected.addAll(
                                  visible.map((entry) => entry.filename))),
                        },
                  child: Focus(
                    child: Builder(
                        builder: (context) => ListView.builder(
                              itemCount: visible.length,
                              itemBuilder: (_, i) {
                                final entry = visible[i];
                                final name = entry.filename;
                                final tile = GestureDetector(
                                  onDoubleTap: _busy
                                      ? null
                                      : () {
                                          if (entry.attr.isDirectory) {
                                            unawaited(_navigate(remoteChild(
                                                _loadedPath, name)));
                                          } else if (entry.attr.isFile) {
                                            unawaited(
                                                _act(_Action.edit, entry));
                                          }
                                        },
                                  onSecondaryTapDown: _busy
                                      ? null
                                      : (event) async {
                                          final overlay = Overlay.of(context)
                                              .context
                                              .findRenderObject()! as RenderBox;
                                          final result =
                                              await showMenu<_Action>(
                                            context: context,
                                            position: RelativeRect.fromSize(
                                                overlay.globalToLocal(
                                                        event.globalPosition) &
                                                    Size.zero,
                                                overlay.size),
                                            items: _menu(entry),
                                          );
                                          if (mounted && result != null) {
                                            await _act(result, entry);
                                          }
                                        },
                                  child: ListTile(
                                    dense: true,
                                    leading: Checkbox(
                                      value: _selected.contains(name),
                                      onChanged: (value) {
                                        Focus.of(context).requestFocus();
                                        setState(() => value!
                                            ? _selected.add(name)
                                            : _selected.remove(name));
                                      },
                                    ),
                                    title: Text(name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis),
                                    subtitle: Text([
                                      if (entry.attr.isDirectory)
                                        l.text('Directory', 'Каталог')
                                      else if (entry.attr.isSymbolicLink)
                                        l.text('Link', 'Ссылка')
                                      else if (entry.attr.size != null)
                                        '${entry.attr.size} ${l.text('B', 'Б')}',
                                      _date(entry.attr.modifyTime),
                                    ].join('   ')),
                                    onTap: () {
                                      Focus.of(context).requestFocus();
                                      setState(() => _selected.contains(name)
                                          ? _selected.remove(name)
                                          : _selected.add(name));
                                    },
                                    trailing: PopupMenuButton<_Action>(
                                      enabled: !_busy,
                                      tooltip: l.text(
                                          'File actions', 'Действия с файлом'),
                                      onSelected: (action) =>
                                          _act(action, entry),
                                      itemBuilder: (_) => _menu(entry),
                                    ),
                                  ),
                                );
                                if (!widget.twoPanes ||
                                    !entry.attr.isFile ||
                                    _local == null ||
                                    _busy) {
                                  return tile;
                                }
                                final entries = _selected.contains(name)
                                    ? _selection
                                        .where((entry) => entry.attr.isFile)
                                        .toList()
                                    : [entry];
                                return Draggable<List<SftpName>>(
                                  data: entries,
                                  feedback: _dragLabel(name, entries.length),
                                  child: tile,
                                );
                              },
                            )),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _localPane(SftpFiles files) {
    final local = _local;
    final directory = _directory;
    return DragTarget<List<SftpName>>(
      onWillAcceptWithDetails: (_) => local != null && !_localBusy && !_busy,
      onAcceptWithDetails: (details) => _download(details.data),
      builder: (context, candidates, _) => Material(
        color: candidates.isNotEmpty
            ? YesDeskColors.of(context).selected
            : YesDeskColors.of(context).surface,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(children: [
              TextButton.icon(
                onPressed: _localBusy
                    ? null
                    : () => _localAction(() async {
                          final folder = await _chooseLocal();
                          if (folder != null) {
                            await _localNavigate(folder, folder.root);
                          }
                        }),
                icon: const Icon(Icons.folder_open),
                label: Text(l.text('Local folder', 'Локальная папка')),
              ),
              if (local != null && directory != null) ...[
                YesDeskIconButton(
                    label: l.text('Parent directory', 'Родительский каталог'),
                    icon: Icons.arrow_upward,
                    onPressed: _localBusy || p.equals(local.root, directory)
                        ? null
                        : () => _localAction(
                            () => _localNavigate(local, p.dirname(directory)))),
                YesDeskIconButton(
                    label:
                        l.text('Upload selected', 'Загрузить выбранные файлы'),
                    icon: Icons.upload,
                    onPressed: _localSelected.isEmpty || _localBusy || _busy
                        ? null
                        : () {
                            _uploadPaths(_localSelected, files, _loadedPath,
                                local: local);
                          }),
              ],
            ]),
            if (directory != null) SelectableText(directory, maxLines: 2),
            Expanded(
              child: ListView.builder(
                itemCount: _localEntries.length,
                itemBuilder: (_, i) {
                  final entry = _localEntries[i];
                  final tile = ListTile(
                    dense: true,
                    leading: entry is File
                        ? Checkbox(
                            value: _localSelected.contains(entry.path),
                            onChanged: (value) => setState(() => value!
                                ? _localSelected.add(entry.path)
                                : _localSelected.remove(entry.path)),
                          )
                        : Icon(entry is Directory
                            ? Icons.folder_outlined
                            : Icons.link),
                    title: Text(p.basename(entry.path),
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    onTap: entry is Directory && local != null && !_localBusy
                        ? () => _localAction(
                            () => _localNavigate(local, entry.path))
                        : null,
                  );
                  if (entry is! File || _busy || _localBusy) return tile;
                  final paths = _localSelected.contains(entry.path)
                      ? _localSelected.toList()
                      : [entry.path];
                  return Draggable<List<String>>(
                    data: paths,
                    feedback: _dragLabel(p.basename(entry.path), paths.length),
                    child: tile,
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _dragLabel(String name, int count) => Material(
        color: YesDeskColors.of(context).selected,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Text(count == 1 ? name : '$name (+${count - 1})'),
        ),
      );

  Widget _queue() {
    return ExpansionTile(
      initiallyExpanded: true,
      title: Text(l.text('Transfers', 'Передачи')),
      trailing: _jobs.any((job) =>
              job.state.index >= _JobState.done.index &&
              job.progress.leftover == null)
          ? YesDeskIconButton(
              label: l.text(
                  'Clear finished transfers', 'Очистить завершённые передачи'),
              icon: Icons.clear_all,
              onPressed: () => setState(() => _jobs.removeWhere((job) =>
                  job.state.index >= _JobState.done.index &&
                  job.progress.leftover == null)))
          : null,
      children: [
        SizedBox(
          height: 120,
          child: ListView.builder(
            itemCount: _jobs.length,
            itemBuilder: (_, i) {
              final job = _jobs[i];
              final progress = job.progress;
              final total = progress.total;
              final fraction = total == null
                  ? null
                  : total == 0
                      ? (job.state == _JobState.done ? 1.0 : 0.0)
                      : (progress.bytes / total).clamp(0.0, 1.0);
              final ms = progress.clock.elapsedMilliseconds;
              final status = switch (job.state) {
                _JobState.waiting => l.text('Queued', 'В очереди'),
                _JobState.running => l.text('Transferring', 'Передача'),
                _JobState.done => l.text('Completed', 'Завершено'),
                _JobState.cancelled => l.text('Cancelled', 'Отменено'),
                _JobState.failed => _message(job.error!),
              };
              final bytes = l.text('B', 'Б');
              return ListTile(
                dense: true,
                title: Text(job.title, overflow: TextOverflow.ellipsis),
                subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(total == null
                          ? status
                          : '$status · ${progress.bytes}/$total $bytes · ${(fraction! * 100).floor()}%'
                              '${ms > 0 ? ' · ${progress.bytes * 1000 ~/ ms} $bytes/s' : ''}'),
                      if (job.state == _JobState.running)
                        LinearProgressIndicator(value: fraction),
                      if (progress.leftover case final path?)
                        SelectableText(
                            '${l.text('Temporary data', 'Временные данные')}  $path'),
                    ]),
                trailing: job.state.index >= _JobState.done.index ||
                        progress.publishing ||
                        progress.cancelled
                    ? null
                    : YesDeskIconButton(
                        label: l.cancel,
                        icon: Icons.close,
                        onPressed: () => setState(() {
                              progress.cancelled = true;
                              if (job.state == _JobState.waiting) {
                                job.state = _JobState.cancelled;
                              }
                            })),
              );
            },
          ),
        ),
      ],
    );
  }

  String _loadedPath = '';

  @override
  Widget build(BuildContext context) {
    final files = _files;
    return Column(
      children: [
        Expanded(
          child: _opening
              ? const Center(child: CircularProgressIndicator())
              : files == null
                  ? Center(
                      child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_error != null)
                          Text(widget.run.ended
                              ? l.text('SSH connection closed',
                                  'SSH-соединение закрыто')
                              : l.text('SFTP unavailable', 'SFTP недоступен')),
                        if (!widget.run.ended)
                          TextButton(
                              onPressed: _connect,
                              child: Text(l.text('Open SFTP', 'Открыть SFTP'))),
                      ],
                    ))
                  : widget.twoPanes
                      ? Row(children: [
                          Expanded(child: _localPane(files)),
                          const VerticalDivider(width: 1),
                          Expanded(child: _remotePane(files)),
                        ])
                      : _remotePane(files),
        ),
        if (_jobs.isNotEmpty) _queue(),
      ],
    );
  }
}

class _TextEditor extends StatefulWidget {
  const _TextEditor(
      {required this.files,
      required this.original,
      required this.labels,
      required this.message});
  final SftpFiles files;
  final RemoteText original;
  final SshStrings labels;
  final String Function(Object) message;

  @override
  State<_TextEditor> createState() => _TextEditorState();
}

class _TextEditorState extends State<_TextEditor> {
  late final _text = TextEditingController(text: widget.original.original);
  bool _saving = false;
  bool _compare = false;
  String? _error;
  SshStrings get l => widget.labels;
  bool get _dirty => _text.text != widget.original.original;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    final progress = TransferProgress();
    try {
      await widget.files.saveText(widget.original, _text.text, progress);
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        final leftover = progress.leftover;
        _error =
            widget.message(error) + (leftover == null ? '' : '\n$leftover');
      });
    }
  }

  Future<void> _close() async {
    if (!_dirty ||
        await sshConfirm(
            context,
            l,
            l.text('Discard unsaved changes?',
                'Отменить несохранённые изменения?'),
            l.text('Discard', 'Отменить изменения'))) {
      if (mounted) Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: Text(widget.original.path,
              maxLines: 2, overflow: TextOverflow.ellipsis),
          content: SizedBox(
            width: 800,
            height: 420,
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_error case final error?) SelectableText(error),
                  if (_dirty)
                    Text(l.text('Unsaved changes', 'Несохранённые изменения')),
                  Expanded(
                      child: Row(children: [
                    if (_compare) ...[
                      Expanded(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                            Text(l.text('Original', 'Исходный текст')),
                            Expanded(
                                child: SingleChildScrollView(
                                    child: SelectableText(
                                        widget.original.original))),
                          ])),
                      const VerticalDivider(),
                    ],
                    Expanded(
                        child: TextField(
                      controller: _text,
                      readOnly: _saving,
                      expands: true,
                      maxLines: null,
                      onChanged: (_) => setState(() {}),
                      textAlignVertical: TextAlignVertical.top,
                      style: const TextStyle(fontFamily: 'monospace'),
                      decoration: InputDecoration(
                          labelText: l.text('UTF-8 text', 'Текст UTF-8')),
                    )),
                  ])),
                  if (_saving) const LinearProgressIndicator(),
                ]),
          ),
          actions: [
            TextButton(
                onPressed: () => setState(() => _compare = !_compare),
                child: Text(_compare
                    ? l.text('Hide original', 'Скрыть исходный текст')
                    : l.text('Compare with original',
                        'Сравнить с исходным текстом'))),
            TextButton(
                onPressed: _saving ? null : _close, child: Text(l.cancel)),
            FilledButton(
                onPressed: _saving || !_dirty ? null : _save,
                child: Text(l.save)),
          ],
        ),
      );
}
