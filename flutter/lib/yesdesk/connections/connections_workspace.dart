import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ssh/widgets/ssh_dialogs.dart';
import '../ssh/widgets/ssh_strings.dart';
import '../theme.dart';
import 'catalog_codec.dart';
import 'catalog_view.dart';
import 'connection_editor.dart';
import 'connection_launcher.dart';
import 'connection_profile.dart';
import 'connection_repository.dart';

enum ConnectionActivity { none, connecting, connected, remoteTab, rdpClient }

enum _Action { connect, edit, duplicate, favorite, pin, delete }

class ConnectionsWorkspace extends StatefulWidget {
  const ConnectionsWorkspace({
    super.key,
    required this.language,
    required this.repository,
    required this.launcher,
    required this.activity,
    this.visible = true,
    this.sessionChanges,
    this.refreshActivity,
  });

  final String language;
  final ConnectionRepository repository;
  final ConnectionLauncher launcher;
  final ConnectionActivity Function(ConnectionProfile) activity;
  final bool visible;
  final Listenable? sessionChanges;
  final Future<void> Function()? refreshActivity;

  @override
  State<ConnectionsWorkspace> createState() => ConnectionsWorkspaceState();
}

class ConnectionsWorkspaceState extends State<ConnectionsWorkspace> {
  final _search = FocusNode();
  final _launching = <String>{};
  ConnectionCatalog? _catalog;
  String? _folder;
  String? _selected;
  CatalogSort _sort = CatalogSort.name;
  CatalogFilter _filter = CatalogFilter.all;
  ConnectionType? _type;
  String _query = '';
  bool _tiles = false;
  bool _loading = false;
  bool _loadFailed = false;
  bool _writing = false;
  Timer? _poll;
  SshStrings get l => SshStrings(widget.language);
  String t(String en, String ru) => l.text(en, ru);

  @override
  void initState() {
    super.initState();
    widget.sessionChanges?.addListener(_changed);
    if (widget.visible) _activate();
  }

  @override
  void didUpdateWidget(ConnectionsWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible && !oldWidget.visible) _activate();
    if (!widget.visible) _poll?.cancel();
  }

  void _activate() {
    unawaited(reload());
    unawaited(_refreshActivity());
    _poll?.cancel();
    if (widget.refreshActivity != null) {
      _poll =
          Timer.periodic(const Duration(seconds: 3), (_) => _refreshActivity());
    }
  }

  Future<void> _refreshActivity() async {
    await widget.refreshActivity?.call();
    if (mounted && widget.visible) setState(() {});
  }

  void _changed() {
    if (mounted && widget.visible) setState(() {});
  }

  @override
  void dispose() {
    widget.sessionChanges?.removeListener(_changed);
    _poll?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> reload() async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final catalog = await widget.repository.load();
      if (!mounted) return;
      setState(() {
        _catalog = catalog;
        _loadFailed = false;
        if (!catalog.folders.containsKey(_folder)) _folder = null;
        if (!catalog.profiles.containsKey(_selected)) _selected = null;
      });
    } catch (_) {
      if (mounted) setState(() => _loadFailed = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void historyUnavailable() => _notice(t('Could not update connection history.',
      'Не удалось обновить историю подключений.'));

  void _notice(String text) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _write(Future<void> Function() operation) async {
    if (_writing) return;
    setState(() => _writing = true);
    try {
      await operation();
    } on FormatException {
      _notice(t('Invalid profile or folder data.',
          'Неверные данные профиля или папки.'));
    } catch (_) {
      _notice(t('Could not save all connection changes.',
          'Не удалось сохранить все изменения подключений.'));
    } finally {
      if (mounted) {
        await reload();
        if (mounted) setState(() => _writing = false);
      }
    }
  }

  Future<void> _edit(
      {ConnectionProfile? profile, bool duplicate = false}) async {
    if (_catalog == null || _loadFailed || _writing) return;
    final result =
        await showDialog<({ConnectionProfile profile, bool clearSecret})>(
      context: context,
      builder: (_) => ConnectionEditor(
        labels: l,
        catalog: _catalog!,
        profile: profile,
        folderId: _folder,
        duplicate: duplicate,
      ),
    );
    if (result == null || !mounted) return;
    await _write(() => widget.repository
        .save(result.profile, clearSecret: result.clearSecret));
    if (mounted && _catalog?.profiles.containsKey(result.profile.id) == true) {
      setState(() => _selected = result.profile.id);
    }
  }

  Future<void> _folderEditor([ConnectionFolder? folder]) async {
    final result = await editFolder(context, l, _catalog!,
        folder?.parentId ?? (folder == null ? _folder : null),
        folder: folder);
    if (result == null || !mounted) return;
    await _write(() => widget.repository.saveFolder(result));
  }

  Future<void> _connect(ConnectionProfile profile) async {
    if (!_launching.add(profile.id)) return;
    setState(() {});
    try {
      final result = await widget.launcher.launch(profile);
      if (result.clientExit case final exit?) unawaited(_watchClient(exit));
      if (profile.type == ConnectionType.remoteDesktop ||
          profile.type == ConnectionType.rdp) {
        try {
          await widget.repository.markConnected(profile.id);
          if (mounted) await reload();
        } catch (_) {
          _notice(t('Could not update connection history.',
              'Не удалось обновить историю подключений.'));
        }
      }
    } on UnsupportedError {
      _notice(t('This connection type is unavailable on this platform.',
          'Этот тип подключения недоступен на данной платформе.'));
    } on FormatException {
      _notice(t('Check the saved address or ID.',
          'Проверьте сохранённый адрес или ID.'));
    } catch (_) {
      _notice(t('Could not launch the connection.',
          'Не удалось запустить подключение.'));
    } finally {
      _launching.remove(profile.id);
      if (mounted) setState(() {});
    }
  }

  Future<void> _watchClient(Future<int> exit) async {
    try {
      final code = await exit;
      if (code != 0) {
        _notice(t('Windows RDP client exited with code $code.',
            'Клиент RDP Windows завершился с кодом $code.'));
      }
    } catch (_) {
      _notice(t('Could not read the RDP client exit status.',
          'Не удалось получить код завершения клиента RDP.'));
    }
    _changed();
  }

  Future<void> _action(ConnectionProfile profile, _Action action) async {
    if (_writing && action != _Action.connect) return;
    switch (action) {
      case _Action.connect:
        await _connect(profile);
      case _Action.edit:
        await _edit(profile: profile);
      case _Action.duplicate:
        await _edit(profile: profile, duplicate: true);
      case _Action.favorite:
        await _write(
            () => widget.repository.setFavorite(profile.id, !profile.favorite));
      case _Action.pin:
        await _write(
            () => widget.repository.setPinned(profile.id, !profile.pinned));
      case _Action.delete:
        final confirmed = await sshConfirm(
          context,
          l,
          t('Delete connection?', 'Удалить подключение?'),
          l.delete,
          content: Text(profile.type == ConnectionType.remoteDesktop
              ? t('${profile.name}\nThe original device history is kept in Remote Desktop.',
                  '${profile.name}\nИстория устройства сохранится в разделе удалённого доступа.')
              : profile.name),
        );
        if (mounted && confirmed) {
          await _write(() => widget.repository.delete(profile.id));
        }
    }
  }

  Future<void> _import() async {
    try {
      final picked = await FilePicker.platform
          .pickFiles(type: FileType.custom, allowedExtensions: ['json']);
      final path = picked?.paths.single;
      if (!mounted || path == null) return;
      final file = File(path);
      if (await file.length() > 10 * 1024 * 1024) {
        throw const FormatException('Catalog too large');
      }
      final text = await file.readAsString();
      if (!mounted) return;
      await _write(() async {
        final count = await widget.repository.importProfiles(text);
        _notice(
            t('Profiles imported: $count', 'Импортировано профилей: $count'));
      });
    } catch (_) {
      _notice(t('Could not read the catalog file.',
          'Не удалось прочитать файл каталога.'));
    }
  }

  Future<void> _export() async {
    final contents = exportCatalog(_catalog!);
    try {
      final path = await FilePicker.platform.saveFile(
        dialogTitle: t('Export connections', 'Экспорт подключений'),
        fileName: 'yesdesk-connections.json',
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (path != null) await File(path).writeAsString(contents, flush: true);
    } catch (_) {
      _notice(t('Could not write the catalog file.',
          'Не удалось записать файл каталога.'));
    }
  }

  String _activity(ConnectionProfile profile) {
    final activity = _launching.contains(profile.id)
        ? ConnectionActivity.connecting
        : widget.activity(profile);
    return switch (activity) {
      ConnectionActivity.connecting => t('Opening…', 'Открытие…'),
      ConnectionActivity.connected => t('Connected', 'Подключено'),
      ConnectionActivity.remoteTab => t('Remote tab open', 'Открыта вкладка'),
      ConnectionActivity.rdpClient =>
        t('RDP client running', 'Клиент RDP запущен'),
      ConnectionActivity.none => t('No local session', 'Нет локальной сессии'),
    };
  }

  List<PopupMenuEntry<_Action>> _menu(ConnectionProfile profile) => [
        PopupMenuItem(value: _Action.connect, child: Text(l.connect)),
        PopupMenuItem(value: _Action.edit, child: Text(l.edit)),
        PopupMenuItem(
            value: _Action.duplicate,
            child: Text(t('Duplicate', 'Дублировать'))),
        PopupMenuItem(
            value: _Action.favorite,
            child: Text(profile.favorite
                ? t('Remove from favorites', 'Убрать из избранного')
                : t('Add to favorites', 'В избранное'))),
        PopupMenuItem(
            value: _Action.pin,
            child: Text(profile.pinned
                ? t('Unpin', 'Открепить')
                : t('Pin', 'Закрепить'))),
        PopupMenuItem(value: _Action.delete, child: Text(l.delete)),
      ];

  Future<void> _contextMenu(ConnectionProfile profile, Offset offset) async {
    setState(() => _selected = profile.id);
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final action = await showMenu<_Action>(
      context: context,
      position: RelativeRect.fromSize(offset & Size.zero, overlay.size),
      items: _menu(profile),
    );
    if (mounted && action != null) await _action(profile, action);
  }

  Widget _entry(ConnectionProfile profile,
      {required bool tile, required bool compact}) {
    final type = connectionTypeLabel(l, profile.type);
    final activity = _activity(profile);
    final selected = _selected == profile.id;
    final title =
        Text(profile.name, maxLines: 1, overflow: TextOverflow.ellipsis);
    final address =
        Text(profile.address, maxLines: 1, overflow: TextOverflow.ellipsis);
    final menu = PopupMenuButton<_Action>(
      tooltip: t('Connection actions', 'Действия подключения'),
      onSelected: (action) => _action(profile, action),
      itemBuilder: (_) => _menu(profile),
    );
    final marker = SizedBox(
        width: 26,
        child: profile.pinned
            ? const Icon(Icons.push_pin_outlined, size: 16)
            : profile.favorite
                ? const Icon(Icons.star_outline, size: 16)
                : null);
    final content = tile || compact
        ? Row(children: [
            marker,
            Expanded(
                child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                title,
                address,
                Text('$type · $activity',
                    maxLines: 2, overflow: TextOverflow.ellipsis),
              ],
            )),
            menu,
          ])
        : Row(children: [
            marker,
            Expanded(flex: 3, child: title),
            Expanded(flex: 3, child: address),
            Expanded(
                flex: 2,
                child:
                    Text(type, maxLines: 1, overflow: TextOverflow.ellipsis)),
            Expanded(
                flex: 2,
                child: Text(activity,
                    maxLines: 1, overflow: TextOverflow.ellipsis)),
            menu,
          ]);
    return Card(
      margin: tile ? const EdgeInsets.all(4) : EdgeInsets.zero,
      color: selected ? Theme.of(context).colorScheme.secondaryContainer : null,
      elevation: 0,
      child: InkWell(
        onTap: () => setState(() => _selected = profile.id),
        onDoubleTap: () => _connect(profile),
        onSecondaryTapDown: (details) =>
            _contextMenu(profile, details.globalPosition),
        child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4), child: content),
      ),
    );
  }

  Widget _details(ConnectionProfile profile) {
    final last = profile.lastConnectedAt?.toLocal();
    final material = MaterialLocalizations.of(context);
    return Material(
      color: YesDeskColors.of(context).surface,
      child: ListView(
        padding: const EdgeInsets.all(YesDeskSpace.md),
        children: [
          Row(children: [
            Expanded(
                child: Text(profile.name,
                    style: Theme.of(context).textTheme.titleMedium)),
            IconButton(
              tooltip: l.close,
              onPressed: () => setState(() => _selected = null),
              icon: const Icon(Icons.close),
            ),
          ]),
          Text(connectionTypeLabel(l, profile.type)),
          SelectableText(profile.address),
          Text(_activity(profile)),
          if (profile.folderId != null)
            Text(_catalog!.folderPath(profile.folderId)),
          if (profile.tags.isNotEmpty) Text(profile.tags.join(', ')),
          if (last != null)
            Text('${t('Last used', 'Последний запуск')} · '
                '${material.formatShortDate(last)} '
                '${material.formatTimeOfDay(TimeOfDay.fromDateTime(last))}'),
          Wrap(spacing: 8, children: [
            FilledButton(
                onPressed: () => _connect(profile), child: Text(l.connect)),
            TextButton(
                onPressed: () => _edit(profile: profile), child: Text(l.edit)),
          ]),
        ],
      ),
    );
  }

  Widget _toolbar(bool enabled) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          TextButton.icon(
              onPressed: enabled ? () => _edit() : null,
              icon: const Icon(Icons.add),
              label: Text(t('New connection', 'Новое подключение'))),
          IconButton(
              tooltip: t('New folder', 'Новая папка'),
              onPressed: enabled ? () => _folderEditor() : null,
              icon: const Icon(Icons.create_new_folder_outlined)),
          IconButton(
              tooltip: t('Import profiles', 'Импорт профилей'),
              onPressed: enabled ? _import : null,
              icon: const Icon(Icons.file_open_outlined)),
          IconButton(
              tooltip: t('Export profiles', 'Экспорт профилей'),
              onPressed: enabled ? _export : null,
              icon: const Icon(Icons.save_alt)),
          IconButton(
              tooltip: _tiles
                  ? t('Table view', 'Таблица')
                  : t('Tile view', 'Плитки'),
              onPressed: () => setState(() => _tiles = !_tiles),
              icon: Icon(_tiles ? Icons.table_rows_outlined : Icons.grid_view)),
          PopupMenuButton<CatalogSort>(
            tooltip: t('Sort', 'Сортировка'),
            icon: const Icon(Icons.sort),
            onSelected: (value) => setState(() => _sort = value),
            itemBuilder: (_) => [
              for (final entry in {
                CatalogSort.name: l.name,
                CatalogSort.address: t('Address', 'Адрес'),
                CatalogSort.type: t('Type', 'Тип'),
                CatalogSort.recent: t('Last used', 'Последний запуск'),
              }.entries)
                CheckedPopupMenuItem(
                    value: entry.key,
                    checked: _sort == entry.key,
                    child: Text(entry.value)),
            ],
          ),
          PopupMenuButton<ConnectionType?>(
            tooltip: t('Filter by type', 'Фильтр по типу'),
            icon: const Icon(Icons.filter_alt_outlined),
            onSelected: (value) => setState(() => _type = value),
            itemBuilder: (_) => [
              CheckedPopupMenuItem(
                value: null,
                checked: _type == null,
                onTap: () => setState(() => _type = null),
                child: Text(t('All types', 'Все типы')),
              ),
              for (final type in ConnectionType.values)
                CheckedPopupMenuItem(
                    value: type,
                    checked: type == _type,
                    child: Text(connectionTypeLabel(l, type))),
            ],
          ),
          for (final entry in {
            CatalogFilter.all: t('All', 'Все'),
            CatalogFilter.favorites: l.favorite,
            CatalogFilter.recent: t('Recent', 'Недавние'),
          }.entries)
            TextButton(
              onPressed: () => setState(() => _filter = entry.key),
              child: Text(entry.value,
                  style: TextStyle(
                      fontWeight:
                          _filter == entry.key ? FontWeight.bold : null)),
            ),
        ]),
      );

  Widget _list(ConnectionCatalog catalog) {
    final folders = catalog.folders.values
        .where((f) => f.parentId == _folder)
        .toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final browse =
        _query.trim().isEmpty && _type == null && _filter == CatalogFilter.all;
    final profiles = catalog.find(
        query: _query,
        filter: _filter,
        sort: _sort,
        folderId: _folder,
        type: _type,
        typeLabel: (type) => connectionTypeLabel(l, type));
    final visible = browse
        ? profiles.where((p) => p.folderId == _folder || p.pinned).toList()
        : profiles;
    return LayoutBuilder(builder: (context, bounds) {
      final scale = MediaQuery.textScalerOf(context);
      final compact = bounds.maxWidth < scale.scale(640);
      final columns = (bounds.maxWidth / scale.scale(285)).floor().clamp(1, 5);
      return CustomScrollView(slivers: [
        if (browse)
          SliverList.builder(
              itemCount: folders.length,
              itemBuilder: (context, index) {
                final folder = folders[index];
                return ListTile(
                  dense: true,
                  leading: const Icon(Icons.folder_outlined),
                  title: Text(folder.name,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  onTap: () => setState(() => _folder = folder.id),
                  trailing: IconButton(
                    tooltip: t('Edit folder', 'Изменить папку'),
                    icon: const Icon(Icons.edit_outlined),
                    onPressed: _writing ? null : () => _folderEditor(folder),
                  ),
                );
              }),
        if (visible.isEmpty && (!browse || folders.isEmpty))
          SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Text(t('No connections here', 'Здесь нет подключений')),
              ))
        else if (_tiles)
          SliverGrid.builder(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns, mainAxisExtent: scale.scale(102)),
            itemCount: visible.length,
            itemBuilder: (_, i) =>
                _entry(visible[i], tile: true, compact: compact),
          )
        else ...[
          if (!compact && visible.isNotEmpty)
            SliverToBoxAdapter(
                child: Padding(
              padding: const EdgeInsets.fromLTRB(30, 4, 52, 4),
              child: Row(children: [
                Expanded(flex: 3, child: Text(l.name)),
                Expanded(flex: 3, child: Text(t('Address', 'Адрес'))),
                Expanded(flex: 2, child: Text(t('Type', 'Тип'))),
                Expanded(flex: 2, child: Text(t('Session', 'Сессия'))),
              ]),
            )),
          SliverList.builder(
            itemCount: visible.length,
            itemBuilder: (_, i) =>
                _entry(visible[i], tile: false, compact: compact),
          ),
        ],
      ]);
    });
  }

  @override
  Widget build(BuildContext context) {
    final catalog = _catalog;
    final selected = catalog?.profiles[_selected];
    final enabled = catalog != null && !_loadFailed && !_writing;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyF, control: true):
            _search.requestFocus,
        const SingleActivator(LogicalKeyboardKey.keyN, control: true): () =>
            _edit(),
        const SingleActivator(LogicalKeyboardKey.enter, control: true): () {
          if (selected != null) _connect(selected);
        },
        const SingleActivator(LogicalKeyboardKey.f2): () {
          if (selected != null) _edit(profile: selected);
        },
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            setState(() => _selected = null),
      },
      child: Focus(
        child:
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: YesDeskSpace.sm),
            child: TextField(
              focusNode: _search,
              onChanged: (value) => setState(() => _query = value),
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                labelText: t('Search connections', 'Поиск подключений'),
              ),
            ),
          ),
          _toolbar(enabled),
          if (_folder != null && catalog != null)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [
                TextButton(
                    onPressed: () => setState(() => _folder = null),
                    child: Text(t('My connections', 'Мои подключения'))),
                for (final folder in catalog.ancestors(_folder))
                  TextButton(
                      onPressed: () => setState(() => _folder = folder.id),
                      child: Text('› ${folder.name}')),
              ]),
            ),
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          const Divider(height: 1),
          Expanded(
            child: _loadFailed
                ? Center(
                    child: TextButton(
                        onPressed: reload,
                        child: Text(t('Could not load connections. Retry',
                            'Не удалось загрузить подключения. Повторить'))))
                : catalog == null
                    ? const SizedBox.shrink()
                    : LayoutBuilder(builder: (context, bounds) {
                        final list = _list(catalog);
                        if (selected == null) return list;
                        if (bounds.maxWidth >=
                            MediaQuery.textScalerOf(context).scale(780)) {
                          return Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Expanded(child: list),
                                const VerticalDivider(width: 1),
                                SizedBox(
                                    width: bounds.maxWidth * 0.32,
                                    child: _details(selected)),
                              ]);
                        }
                        return Column(children: [
                          Expanded(child: list),
                          const Divider(height: 1),
                          SizedBox(
                              height: bounds.maxHeight * 0.42,
                              child: _details(selected)),
                        ]);
                      }),
          ),
        ]),
      ),
    );
  }
}
