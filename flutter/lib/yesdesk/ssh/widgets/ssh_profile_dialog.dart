import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../models/ssh_profile.dart';
import 'ssh_strings.dart';

class SshProfileDialog extends StatefulWidget {
  const SshProfileDialog({
    super.key,
    required this.labels,
    required this.groups,
    this.profile,
  });

  final SshStrings labels;
  final List<String> groups;
  final SshProfile? profile;

  @override
  State<SshProfileDialog> createState() => _SshProfileDialogState();
}

class _SshProfileDialogState extends State<SshProfileDialog> {
  final _form = GlobalKey<FormState>();
  late final _old = widget.profile;
  late final _name = _old?.name ?? '';
  late String _host = _old?.host ?? '';
  late int _port = _old?.port ?? 22;
  late String _username = _old?.username ?? '';
  late String _group = _old?.group ?? '';
  late String _comment = _old?.comment ?? '';
  late int _timeout = _old?.timeoutSeconds ?? 15;
  late double _fontSize = _old?.fontSize ?? 14;
  late int _scrollback = _old?.scrollback ?? 5000;
  late SshAuth _auth = _old?.auth ?? SshAuth.password;
  late SshPalette _palette = _old?.palette ?? SshPalette.dark;
  late bool _favorite = _old?.favorite ?? false;
  bool _forgetCredential = false;
  String? _editedName;
  SshStrings get l => widget.labels;

  Widget _field(String label, String value, ValueChanged<String> save,
      {bool Function(String)? valid, bool numeric = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        initialValue: value,
        decoration: InputDecoration(labelText: label),
        keyboardType: numeric ? TextInputType.number : TextInputType.text,
        validator: (value) => valid == null || valid(value?.trim() ?? '')
            ? null
            : l.text('Invalid value', 'Недопустимое значение'),
        onSaved: (value) => save(value?.trim() ?? ''),
      ),
    );
  }

  Widget _number(
      String label, int value, int min, int max, ValueChanged<int> save) {
    return _field(label, '$value', (str) => save(int.parse(str)), numeric: true,
        valid: (str) {
      final number = int.tryParse(str);
      return number != null && number >= min && number <= max;
    });
  }

  void _save() {
    final form = _form.currentState!;
    if (!form.validate()) return;
    form.save();
    final host = SshProfile.normalizeHost(_host);
    final old = _old;
    final keepSecret = !_forgetCredential &&
        old != null &&
        SshProfile.normalizeHost(old.host) == host &&
        old.port == _port &&
        old.username == _username &&
        old.auth == _auth;
    Navigator.pop(
        context,
        SshProfile(
          id: old?.id ?? const Uuid().v4(),
          name: _editedName ?? _name,
          host: host,
          port: _port,
          username: _username,
          group: _group,
          comment: _comment,
          timeoutSeconds: _timeout,
          fontSize: _fontSize,
          scrollback: _scrollback,
          auth: _auth,
          palette: _palette,
          favorite: _favorite,
          secretRef: keepSecret ? old.secretRef : null,
        ));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(_old == null
            ? l.text('New connection', 'Новое подключение')
            : l.edit),
        content: SizedBox(
          width: 430,
          child: Form(
            key: _form,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _field(l.name, _name, (v) => _editedName = v,
                      valid: (v) => v.isNotEmpty),
                  _field(l.host, _host, (v) => _host = v,
                      valid: SshProfile.validHost),
                  _number(l.text('Port', 'Порт'), _port, 1, 65535,
                      (v) => _port = v),
                  _field(l.text('Username', 'Пользователь'), _username,
                      (v) => _username = v,
                      valid: (v) => v.isNotEmpty),
                  DropdownButtonFormField<SshAuth>(
                    value: _auth,
                    decoration: InputDecoration(
                        labelText: l.text('Authentication', 'Аутентификация')),
                    items: [
                      DropdownMenuItem(
                          value: SshAuth.password, child: Text(l.password)),
                      DropdownMenuItem(
                          value: SshAuth.privateKey, child: Text(l.privateKey)),
                      DropdownMenuItem(
                          value: SshAuth.keyboardInteractive,
                          child: Text(l.keyboardInteractive)),
                    ],
                    onChanged: (value) => setState(() => _auth = value!),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    value: _group,
                    isExpanded: true,
                    decoration: InputDecoration(labelText: l.group),
                    items: [
                      DropdownMenuItem(
                          value: '',
                          child: Text(l.text('Ungrouped', 'Без группы'))),
                      for (final group in {
                        ...widget.groups,
                        if (_group.isNotEmpty) _group
                      })
                        DropdownMenuItem(value: group, child: Text(group)),
                    ],
                    onChanged: (value) => setState(() => _group = value!),
                  ),
                  const SizedBox(height: 12),
                  _field(l.text('Comment', 'Комментарий'), _comment,
                      (v) => _comment = v),
                  _number(
                      l.text(
                          'Connection timeout (s)', 'Тайм-аут подключения (с)'),
                      _timeout,
                      1,
                      120,
                      (v) => _timeout = v),
                  _field(l.text('Font size', 'Размер шрифта'), '$_fontSize',
                      (v) => _fontSize = double.parse(v), numeric: true,
                      valid: (v) {
                    final size = double.tryParse(v);
                    return size != null && size >= 8 && size <= 36;
                  }),
                  _number(l.text('Scrollback lines', 'Строк в истории'),
                      _scrollback, 100, 20000, (v) => _scrollback = v),
                  DropdownButtonFormField<SshPalette>(
                    value: _palette,
                    decoration: InputDecoration(
                        labelText:
                            l.text('Terminal palette', 'Палитра терминала')),
                    items: [
                      DropdownMenuItem(
                          value: SshPalette.dark, child: Text(l.dark)),
                      DropdownMenuItem(
                          value: SshPalette.light, child: Text(l.light)),
                    ],
                    onChanged: (value) => setState(() => _palette = value!),
                  ),
                  CheckboxListTile(
                    value: _favorite,
                    title: Text(l.favorite),
                    onChanged: (value) => setState(() => _favorite = value!),
                  ),
                  if (_old?.secretRef != null)
                    CheckboxListTile(
                      value: _forgetCredential,
                      title: Text(l.text('Forget saved credential',
                          'Забыть сохранённые данные')),
                      onChanged: (value) =>
                          setState(() => _forgetCredential = value!),
                    ),
                ],
              ),
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
