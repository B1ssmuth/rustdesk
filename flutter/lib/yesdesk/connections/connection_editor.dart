import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../ssh/models/ssh_profile.dart';
import '../ssh/widgets/ssh_strings.dart';
import 'catalog_codec.dart';
import 'catalog_view.dart';
import 'connection_profile.dart';

String connectionTypeLabel(SshStrings l, ConnectionType type) => switch (type) {
      ConnectionType.remoteDesktop =>
        l.text('Remote Desktop', 'Удалённый рабочий стол'),
      ConnectionType.ssh => l.title,
      ConnectionType.sftp => l.text('SFTP Explorer', 'Проводник SFTP'),
      ConnectionType.rdp => 'Windows RDP',
    };

List<DropdownMenuItem<String>> folderChoices(
  SshStrings l,
  ConnectionCatalog catalog, {
  String? exclude,
}) {
  final folders = catalog.folders.values
      .where((f) =>
          exclude == null ||
          !catalog.ancestors(f.id).any((ancestor) => ancestor.id == exclude))
      .map((folder) => (id: folder.id, path: catalog.folderPath(folder.id)))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  return [
    DropdownMenuItem(value: '', child: Text(l.text('No folder', 'Без папки'))),
    for (final folder in folders)
      DropdownMenuItem(
        value: folder.id,
        child: Text(folder.path, overflow: TextOverflow.ellipsis),
      ),
  ];
}

class ConnectionEditor extends StatefulWidget {
  const ConnectionEditor({
    super.key,
    required this.labels,
    required this.catalog,
    this.profile,
    this.folderId,
    this.duplicate = false,
  });

  final SshStrings labels;
  final ConnectionCatalog catalog;
  final ConnectionProfile? profile;
  final String? folderId;
  final bool duplicate;

  @override
  State<ConnectionEditor> createState() => _ConnectionEditorState();
}

class _ConnectionEditorState extends State<ConnectionEditor> {
  final _form = GlobalKey<FormState>();
  ConnectionProfile? get old => widget.profile;
  SshStrings get l => widget.labels;
  late final String _id =
      widget.duplicate ? const Uuid().v4() : old?.id ?? const Uuid().v4();
  late ConnectionType _type = old?.type ?? ConnectionType.remoteDesktop;
  late String _folder = old?.folderId ?? widget.folderId ?? '';
  late String _name = widget.duplicate
      ? l.text('Copy of ${old!.name}', 'Копия ${old!.name}')
      : old?.name ?? '';
  late String _host = old?.host ?? '';
  late String _username = old?.username ?? '';
  late String _tags = old?.tags.join(', ') ?? '';
  late int? _port = old?.port;
  late final Json _settings =
      old == null ? {} : transportSettings(old!.options);
  bool _forget = false;
  String? _error;

  Widget _field(
    String label,
    String value,
    ValueChanged<String> change, {
    bool autofocus = false,
    bool numeric = false,
  }) =>
      Padding(
        padding: const EdgeInsets.only(top: 8),
        child: TextFormField(
          initialValue: value,
          autofocus: autofocus,
          decoration: InputDecoration(labelText: label),
          keyboardType: numeric ? TextInputType.number : TextInputType.text,
          onChanged: change,
        ),
      );

  Widget _number(String label, String name, int fallback) => _field(
      label,
      '${_settings[name] ?? fallback}',
      (v) => _settings[name] = int.tryParse(v) ?? -1,
      numeric: true);

  Widget _flag(String label, String name, {bool defaultValue = false}) =>
      CheckboxListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(label),
        value: _settings[name] as bool? ?? defaultValue,
        onChanged: (value) => setState(() => _settings[name] = value!),
      );

  void _save() {
    final host = _host
        .trim()
        .replaceAll(_type == ConnectionType.remoteDesktop ? ' ' : '\x00', '');
    try {
      final options = transportOptions(
          _type, _id, _name.trim(), host, _port, _username.trim(), _settings);
      final profile = ConnectionProfile(
        id: _id,
        name: _name.trim(),
        host: host,
        port: _port,
        username: _username.trim(),
        options: options,
        folderId: _folder.isEmpty ? null : _folder,
        tags: _tags
            .split(',')
            .map((tag) => tag.trim())
            .where((tag) => tag.isNotEmpty),
        favorite: !widget.duplicate && (old?.favorite ?? false),
        pinned: !widget.duplicate && (old?.pinned ?? false),
      );
      decodeProfile(encodeProfile(profile));
      Navigator.pop(context, (profile: profile, clearSecret: _forget));
    } on FormatException {
      setState(() => _error = l.text(
          'Check the name, address, port and transport settings.',
          'Проверьте название, адрес, порт и параметры транспорта.'));
    } on ArgumentError {
      setState(() => _error = l.text(
          'Invalid transport settings', 'Неверные параметры транспорта'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final isRemote = _type == ConnectionType.remoteDesktop;
    final isSsh = _type == ConnectionType.ssh || _type == ConnectionType.sftp;
    return AlertDialog(
      scrollable: true,
      title: Text(widget.duplicate
          ? l.text('Duplicate connection', 'Дублировать подключение')
          : old == null
              ? l.text('New connection', 'Новое подключение')
              : l.edit),
      content: SizedBox(
        width: 480,
        child: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<ConnectionType>(
                value: _type,
                decoration: InputDecoration(labelText: l.text('Type', 'Тип')),
                isExpanded: true,
                items: [
                  for (final type in ConnectionType.values)
                    DropdownMenuItem(
                      value: type,
                      child: Text(connectionTypeLabel(l, type),
                          overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: old != null
                    ? null
                    : (value) => setState(() {
                          _type = value!;
                          _port = null;
                          _settings.clear();
                          _error = null;
                        }),
              ),
              _field(l.name, _name, (v) => _name = v, autofocus: true),
              _field(isRemote ? l.text('Host or ID', 'Хост или ID') : l.host,
                  _host, (v) => _host = v),
              KeyedSubtree(
                key: ValueKey(_type),
                child: Column(
                  children: [
                    if (!isRemote) ...[
                      _field(
                          l.text('Port', 'Порт'),
                          '${_port ?? (isSsh ? 22 : 3389)}',
                          (v) => _port = int.tryParse(v) ?? -1,
                          numeric: true),
                      _field(l.text('Username', 'Пользователь'), _username,
                          (v) => _username = v),
                    ],
                    if (isRemote)
                      _flag(l.text('Force relay', 'Использовать ретранслятор'),
                          'forceRelay'),
                    if (isSsh) ...[
                      DropdownButtonFormField<String>(
                        value: _settings['auth'] as String? ??
                            SshAuth.password.name,
                        decoration: InputDecoration(
                            labelText:
                                l.text('Authentication', 'Аутентификация')),
                        items: [
                          DropdownMenuItem(
                              value: SshAuth.password.name,
                              child: Text(l.password)),
                          DropdownMenuItem(
                              value: SshAuth.privateKey.name,
                              child: Text(l.privateKey)),
                          DropdownMenuItem(
                              value: SshAuth.keyboardInteractive.name,
                              child: Text(l.keyboardInteractive)),
                        ],
                        isExpanded: true,
                        onChanged: (value) => _settings['auth'] = value!,
                      ),
                      _number(l.text('Timeout (seconds)', 'Тайм-аут (секунды)'),
                          'timeoutSeconds', 15),
                    ],
                    if (_type == ConnectionType.rdp) ...[
                      _field(
                          'RD Gateway',
                          _settings['gateway'] as String? ?? '',
                          (v) => _settings['gateway'] = v.trim()),
                      _number(l.text('Width', 'Ширина'), 'width', 1600),
                      _number(l.text('Height', 'Высота'), 'height', 900),
                      _flag(l.text('Scale to window', 'Масштабировать по окну'),
                          'scaleToWindow',
                          defaultValue: true),
                      _flag(l.text('Fullscreen', 'Полноэкранный режим'),
                          'fullscreen'),
                      _flag(l.text('Share clipboard', 'Общий буфер обмена'),
                          'clipboard'),
                    ],
                  ],
                ),
              ),
              DropdownButtonFormField<String>(
                value: _folder,
                decoration:
                    InputDecoration(labelText: l.text('Folder', 'Папка')),
                isExpanded: true,
                items: folderChoices(l, widget.catalog),
                onChanged: (value) => _folder = value!,
              ),
              _field(l.text('Tags (comma separated)', 'Теги (через запятую)'),
                  _tags, (v) => _tags = v),
              if (!widget.duplicate && old?.secretRef != null)
                CheckboxListTile(
                  title: Text(l.text(
                      'Forget saved credential', 'Забыть учётные данные')),
                  value: _forget,
                  onChanged: (value) => setState(() => _forget = value!),
                ),
              if (_error != null)
                Text(_error!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: Text(l.cancel)),
        FilledButton(onPressed: _save, child: Text(l.save)),
      ],
    );
  }
}

Future<ConnectionFolder?> editFolder(
  BuildContext context,
  SshStrings l,
  ConnectionCatalog catalog,
  String? parentId, {
  ConnectionFolder? folder,
}) {
  var name = folder?.name ?? '';
  var parent = parentId ?? '';
  return showDialog<ConnectionFolder>(
    context: context,
    builder: (context) => AlertDialog(
      scrollable: true,
      title: Text(folder == null
          ? l.text('New folder', 'Новая папка')
          : l.text('Edit folder', 'Изменить папку')),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              autofocus: true,
              initialValue: name,
              decoration: InputDecoration(labelText: l.name),
              onChanged: (value) => name = value.trim(),
            ),
            DropdownButtonFormField<String>(
              value: parent,
              decoration: InputDecoration(
                  labelText: l.text('Parent folder', 'Родительская папка')),
              isExpanded: true,
              items: folderChoices(l, catalog, exclude: folder?.id),
              onChanged: (value) => parent = value!,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: Text(l.cancel)),
        FilledButton(
          onPressed: () => Navigator.pop(
              context,
              ConnectionFolder(folder?.id ?? const Uuid().v4(), name,
                  parent.isEmpty ? null : parent)),
          child: Text(l.save),
        ),
      ],
    ),
  );
}
