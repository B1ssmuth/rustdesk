import 'dart:async';

import 'package:flutter/material.dart';

import '../theme.dart';
import 'rdp_launcher.dart';
import 'rdp_profile.dart';
import 'rdp_profile_store.dart';

class RdpWorkspace extends StatefulWidget {
  const RdpWorkspace({
    super.key,
    required this.language,
    this.store,
    this.launcher,
  });

  final String language;
  final RdpProfileStore? store;
  final RdpLauncher? launcher;

  @override
  State<RdpWorkspace> createState() => _RdpWorkspaceState();
}

class _RdpWorkspaceState extends State<RdpWorkspace> {
  late final _store = widget.store ?? RdpProfileStore();
  late final _launcher = widget.launcher ?? RdpLauncher();
  List<RdpProfile> _profiles = [];
  final Set<String> _launching = {};
  bool _loading = true;
  bool _loadFailed = false;
  bool _saving = false;

  String _text(String en, String ru) => _translate(widget.language, en, ru);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadFailed = false;
    });
    try {
      final profiles = await _store.load();
      if (mounted) setState(() => _profiles = profiles);
    } catch (_) {
      if (mounted) setState(() => _loadFailed = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _notify(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _update(Future<List<RdpProfile>> Function() update) async {
    setState(() => _saving = true);
    try {
      final profiles = await update();
      if (mounted) setState(() => _profiles = profiles);
    } catch (_) {
      _notify(_text(
          'Could not save RDP profiles.', 'Не удалось сохранить профили RDP.'));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _edit([RdpProfile? profile]) async {
    final updated = await showDialog<RdpProfile>(
      context: context,
      builder: (_) =>
          _RdpProfileDialog(language: widget.language, profile: profile),
    );
    if (mounted && updated != null) await _update(() => _store.save(updated));
  }

  Future<void> _delete(RdpProfile profile) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_text('Delete RDP profile?', 'Удалить профиль RDP?')),
        content: Text(profile.name),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(_text('Cancel', 'Отмена'))),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(_text('Delete', 'Удалить'))),
        ],
      ),
    );
    if (mounted && confirmed == true) {
      await _update(() => _store.delete(profile.id));
    }
  }

  Future<void> _connect(RdpProfile profile) async {
    if (_launching.contains(profile.id)) return;
    setState(() => _launching.add(profile.id));
    try {
      final client = await _launcher.launch(profile);
      _notify(_text('Opened Windows Remote Desktop Connection.',
          'Клиент удалённых рабочих столов Windows запущен.'));
      unawaited(_watchClient(client.exitCode));
    } catch (_) {
      _notify(_text('Could not start the Windows RDP client.',
          'Не удалось запустить клиент RDP Windows.'));
    } finally {
      if (mounted) setState(() => _launching.remove(profile.id));
    }
  }

  Future<void> _watchClient(Future<int> exited) async {
    try {
      final code = await exited;
      if (code != 0) {
        _notify(_text('Windows RDP client exited with code $code.',
            'Клиент RDP Windows завершился с кодом $code.'));
      }
    } catch (_) {
      _notify(_text('Could not read the RDP client exit status.',
          'Не удалось получить код завершения клиента RDP.'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(YesDeskSpace.lg),
      children: [
        Wrap(
          spacing: YesDeskSpace.lg,
          runSpacing: YesDeskSpace.sm,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text('Windows RDP', style: theme.textTheme.titleLarge),
            ElevatedButton.icon(
              onPressed: _loading || _loadFailed || _saving ? null : _edit,
              icon: const Icon(Icons.add),
              label: Text(_text('New profile', 'Новый профиль')),
            ),
          ],
        ),
        const SizedBox(height: YesDeskSpace.sm),
        Text(
          _text(
            'Each connection opens in the Windows Remote Desktop client. Enter or save credentials in the Windows sign-in prompt.',
            'Каждое подключение открывается в клиенте удалённых рабочих столов Windows. Вводите и сохраняйте учётные данные в окне входа Windows.',
          ),
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: YesDeskSpace.lg),
        if (_loading)
          const LinearProgressIndicator()
        else if (_loadFailed) ...[
          Text(_text('Could not load RDP profiles.',
              'Не удалось загрузить профили RDP.')),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
                onPressed: _load, child: Text(_text('Retry', 'Повторить'))),
          ),
        ] else if (_profiles.isEmpty)
          Text(_text('Add a profile for a Windows server or workstation.',
              'Добавьте профиль сервера или рабочей станции Windows.'))
        else
          for (final profile in _profiles)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(YesDeskSpace.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(profile.name, style: theme.textTheme.titleMedium),
                    Text(profile.endpoint.address),
                    if (profile.username.isNotEmpty) Text(profile.username),
                    if (profile.gateway.isNotEmpty)
                      Text('RD Gateway · ${profile.gateway}'),
                    const SizedBox(height: YesDeskSpace.sm),
                    Wrap(
                      spacing: YesDeskSpace.sm,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        OutlinedButton(
                          onPressed: _launching.contains(profile.id)
                              ? null
                              : () => _connect(profile),
                          child: Text(_text('Connect', 'Подключить')),
                        ),
                        IconButton(
                          tooltip: _text('Edit profile', 'Изменить профиль'),
                          onPressed: _saving ? null : () => _edit(profile),
                          icon: const Icon(Icons.edit_outlined),
                        ),
                        IconButton(
                          tooltip: _text('Delete profile', 'Удалить профиль'),
                          onPressed: _saving ? null : () => _delete(profile),
                          icon: const Icon(Icons.delete_outline),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
      ],
    );
  }
}

String _translate(String language, String en, String ru) =>
    language.toLowerCase().startsWith('ru') ? ru : en;

class _RdpProfileDialog extends StatefulWidget {
  const _RdpProfileDialog({required this.language, this.profile});

  final String language;
  final RdpProfile? profile;

  @override
  State<_RdpProfileDialog> createState() => _RdpProfileDialogState();
}

class _RdpProfileDialogState extends State<_RdpProfileDialog> {
  final _form = GlobalKey<FormState>();
  RdpProfile? get _profile => widget.profile;

  late final _name = TextEditingController(text: _profile?.name);
  late final _host = TextEditingController(text: _profile?.endpoint.host);
  late final _port =
      TextEditingController(text: '${_profile?.endpoint.port ?? 3389}');
  late final _username = TextEditingController(text: _profile?.username);
  late final _gateway = TextEditingController(text: _profile?.gateway);
  late final _width = TextEditingController(text: '${_profile?.width ?? 1600}');
  late final _height =
      TextEditingController(text: '${_profile?.height ?? 900}');
  late bool _fullscreen = _profile?.fullscreen ?? false;
  late bool _scale = _profile?.scaleToWindow ?? true;
  late bool _clipboard = _profile?.clipboard ?? false;

  String _text(String en, String ru) => _translate(widget.language, en, ru);

  @override
  void dispose() {
    for (final field in [
      _name,
      _host,
      _port,
      _username,
      _gateway,
      _width,
      _height
    ]) {
      field.dispose();
    }
    super.dispose();
  }

  void _submit() {
    if (!_form.currentState!.validate()) return;
    final profile = RdpProfile(
      id: _profile?.id,
      name: _name.text,
      endpoint: RdpEndpoint.parse(_host.text, int.tryParse(_port.text))!,
      username: _username.text,
      gateway: _gateway.text,
      width: int.parse(_width.text),
      height: int.parse(_height.text),
      fullscreen: _fullscreen,
      scaleToWindow: _scale,
      clipboard: _clipboard,
    );
    Navigator.pop(context, profile);
  }

  Widget _field(
    TextEditingController controller,
    String label,
    String? Function(String) error, {
    bool number = false,
    String? hint,
  }) {
    return TextFormField(
      controller: controller,
      keyboardType: number ? TextInputType.number : TextInputType.text,
      decoration:
          InputDecoration(labelText: label, hintText: hint, errorMaxLines: 2),
      validator: (value) => error(value ?? ''),
    );
  }

  @override
  Widget build(BuildContext context) {
    String? dimension(String value) =>
        RdpProfile.validDimension(int.tryParse(value))
            ? null
            : _text('200–8192 pixels', '200–8192 пикселей');
    return AlertDialog(
      scrollable: true,
      title: Text(_profile == null
          ? _text('New RDP profile', 'Новый профиль RDP')
          : _text('Edit RDP profile', 'Изменить профиль RDP')),
      content: SizedBox(
        width: 440,
        child: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _field(
                  _name,
                  _text('Profile name', 'Имя профиля'),
                  (value) => value.trim().isNotEmpty &&
                          RdpProfile.validText(value, 100)
                      ? null
                      : _text('Enter a name', 'Введите имя')),
              _field(
                  _host,
                  _text('Host or IP address', 'Имя хоста или IP-адрес'),
                  (value) => RdpEndpoint.parse(value, 3389) != null
                      ? null
                      : _text('Enter a DNS name or IP address',
                          'Введите имя DNS или IP-адрес')),
              _field(_port, _text('Port', 'Порт'), (value) {
                final port = int.tryParse(value);
                return port != null && port >= 1 && port <= 65535
                    ? null
                    : '1–65535';
              }, number: true),
              _field(
                  _username,
                  _text('Windows username (optional)',
                      'Имя пользователя Windows (необязательно)'),
                  (value) => RdpProfile.validText(value, 256)
                      ? null
                      : _text(
                          'Invalid username', 'Некорректное имя пользователя'),
                  hint: r'DOMAIN\user, user@example.com'),
              _field(
                  _gateway,
                  _text('RD Gateway DNS name (optional)',
                      'Имя DNS шлюза RD Gateway (необязательно)'),
                  (value) => RdpProfile.validGateway(value)
                      ? null
                      : _text('Enter a DNS name', 'Введите имя DNS')),
              Row(
                children: [
                  Expanded(
                      child: _field(_width, _text('Width', 'Ширина'), dimension,
                          number: true)),
                  const SizedBox(width: YesDeskSpace.sm),
                  Expanded(
                      child: _field(
                          _height, _text('Height', 'Высота'), dimension,
                          number: true)),
                ],
              ),
              SwitchListTile(
                title: Text(
                    _text('Scale to window', 'Масштабировать по размеру окна')),
                value: _scale,
                onChanged: (value) => setState(() => _scale = value),
              ),
              SwitchListTile(
                title:
                    Text(_text('Start fullscreen', 'Открывать на весь экран')),
                value: _fullscreen,
                onChanged: (value) => setState(() => _fullscreen = value),
              ),
              SwitchListTile(
                title: Text(_text('Share clipboard', 'Общий буфер обмена')),
                value: _clipboard,
                onChanged: (value) => setState(() => _clipboard = value),
              ),
            ]
                .map((child) => Padding(
                      padding: const EdgeInsets.only(bottom: YesDeskSpace.sm),
                      child: child,
                    ))
                .toList(),
          ),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(_text('Cancel', 'Отмена'))),
        ElevatedButton(
            onPressed: _submit, child: Text(_text('Save', 'Сохранить'))),
      ],
    );
  }
}
