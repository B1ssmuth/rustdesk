import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'ssh_strings.dart';

Future<T?> sshDialog<T>(
  BuildContext context,
  WidgetBuilder builder, {
  Future<void>? ended,
}) {
  final navigator = Navigator.of(context, rootNavigator: true);
  final route = DialogRoute<T>(
    context: context,
    builder: builder,
    themes: InheritedTheme.capture(from: context, to: navigator.context),
  );
  final result = navigator.push(route);
  if (ended == null) return result;
  return Future.any([
    result,
    ended.then<T?>((_) {
      if (navigator.mounted && route.isActive) navigator.removeRoute(route);
      return null;
    }),
  ]);
}

Future<String?> sshTextDialog(BuildContext context, SshStrings l, String label,
        {String initialValue = ''}) =>
    sshDialog(
        context,
        (_) =>
            _TextPrompt(labels: l, label: label, initialValue: initialValue));

class _TextPrompt extends StatefulWidget {
  const _TextPrompt(
      {required this.labels, required this.label, required this.initialValue});
  final SshStrings labels;
  final String label;
  final String initialValue;

  @override
  State<_TextPrompt> createState() => _TextPromptState();
}

class _TextPromptState extends State<_TextPrompt> {
  late String _value = widget.initialValue;

  void _submit() {
    if (_value.trim().isNotEmpty) Navigator.pop(context, _value.trim());
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.label),
        content: TextFormField(
          initialValue: widget.initialValue,
          autofocus: true,
          onChanged: (value) => setState(() => _value = value),
          onFieldSubmitted: (_) => _submit(),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(widget.labels.cancel)),
          FilledButton(
              onPressed: _value.trim().isEmpty ? null : _submit,
              child: Text(widget.labels.save)),
        ],
      );
}

Future<bool> sshConfirm(
        BuildContext context, SshStrings labels, String title, String action,
        {Widget? content, Future<void>? ended}) async =>
    await sshDialog<bool>(
        context,
        (context) => AlertDialog(
              title: Text(title),
              content: content,
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: Text(labels.cancel)),
                FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: Text(action)),
              ],
            ),
        ended: ended) ??
    false;

typedef SshCredential = ({String secret, String? keyPath, bool remember});

class SshCredentialDialog extends StatefulWidget {
  const SshCredentialDialog({
    super.key,
    required this.labels,
    required this.destination,
    required this.privateKey,
    required this.canPersist,
    this.saved,
  });

  final SshStrings labels;
  final String destination;
  final bool privateKey;
  final bool canPersist;
  final SshCredential? saved;

  @override
  State<SshCredentialDialog> createState() => _SshCredentialDialogState();
}

class _SshCredentialDialogState extends State<SshCredentialDialog> {
  final _secret = TextEditingController();
  final _path = TextEditingController();
  bool _remember = false;
  bool _picking = false;
  bool _pickerError = false;
  SshStrings get l => widget.labels;

  @override
  void dispose() {
    _secret.dispose();
    _path.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    setState(() {
      _picking = true;
      _pickerError = false;
    });
    try {
      final result =
          await FilePicker.platform.pickFiles(dialogTitle: l.privateKey);
      final path = result?.files.single.path;
      if (mounted && path != null) _path.text = path;
    } catch (_) {
      if (mounted) setState(() => _pickerError = true);
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  void _submit() {
    final path = _path.text.trim();
    if (widget.privateKey ? path.isEmpty : _secret.text.isEmpty) return;
    Navigator.pop(context, (
      secret: _secret.text,
      keyPath: widget.privateKey ? path : null,
      remember: _remember,
    ));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.privateKey ? l.privateKey : l.password),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.destination),
                const SizedBox(height: 12),
                if (widget.privateKey) ...[
                  TextField(
                    controller: _path,
                    enableSuggestions: false,
                    autocorrect: false,
                    decoration: InputDecoration(
                      labelText: l.text('Key file', 'Файл ключа'),
                      errorText: _pickerError
                          ? l.text('File picker unavailable',
                              'Выбор файла недоступен')
                          : null,
                      suffixIcon: IconButton(
                        tooltip: l.text('Choose file', 'Выбрать файл'),
                        onPressed: _picking ? null : _pick,
                        icon: const Icon(Icons.folder_open),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                TextField(
                  controller: _secret,
                  autofocus: !widget.privateKey,
                  obscureText: true,
                  enableSuggestions: false,
                  autocorrect: false,
                  decoration: InputDecoration(
                      labelText: widget.privateKey ? l.passphrase : l.password),
                  onSubmitted: (_) => _submit(),
                ),
                if (widget.canPersist)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _remember,
                    title: Text(l.text('Save in Windows Credential Manager',
                        'Сохранить в диспетчере учётных данных Windows')),
                    onChanged: (value) => setState(() => _remember = value!),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(l.text('Use for this connection only',
                        'Только для этого подключения')),
                  ),
                if (widget.saved != null)
                  TextButton(
                    onPressed: () => Navigator.pop(context, widget.saved),
                    child: Text(l.text('Use saved credential',
                        'Использовать сохранённые данные')),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: Text(l.cancel)),
          FilledButton(onPressed: _submit, child: Text(l.connect)),
        ],
      );
}
