import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../theme.dart';
import '../../widgets.dart';
import '../controllers/ssh_tab.dart';
import '../models/ssh_profile.dart';
import '../services/ssh_transport.dart';
import '../storage/ssh_repository.dart';
import '../storage/ssh_secrets.dart';
import '../widgets/ssh_dialogs.dart';
import '../widgets/ssh_profile_dialog.dart';
import '../widgets/ssh_strings.dart';
import '../widgets/ssh_terminal_view.dart';

class SshWorkspace extends StatefulWidget {
  const SshWorkspace({
    super.key,
    required this.language,
    this.repository,
    this.secrets = const SystemSshSecretStore(),
  });

  final String language;
  final SshRepository? repository;
  final SshSecretStore secrets;

  @override
  State<SshWorkspace> createState() => _SshWorkspaceState();
}

class _SshWorkspaceState extends State<SshWorkspace> {
  late final _repository = widget.repository ?? SshRepository();
  final _tabs = <SshTab>[];
  List<SshProfile> _profiles = [];
  List<String> _groups = [];
  String _query = '';
  bool _favorites = false;
  bool _showProfiles = true;
  bool _loading = true;
  bool _loadFailed = false;
  SshTab? _current;
  SshStrings get l => SshStrings(widget.language);
  SshSecretStore get _secrets => widget.secrets;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    for (final tab in _tabs) {
      tab.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final data = await _repository.load();
      if (!mounted) return;
      setState(() {
        _profiles = data.profiles
          ..sort((a, b) {
            if (a.favorite != b.favorite) return a.favorite ? -1 : 1;
            return a.name.toLowerCase().compareTo(b.name.toLowerCase());
          });
        _groups = data.groups..sort();
        _loading = false;
        _loadFailed = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadFailed = true;
        });
      }
    }
  }

  Future<void> _edit([SshProfile? profile]) async {
    final updated = await sshDialog<SshProfile>(context,
        (_) => SshProfileDialog(labels: l, groups: _groups, profile: profile));
    if (!mounted || updated == null) return;
    await _update(() async {
      final removed = await _repository.save(updated,
          clearSecret: profile?.secretRef != null && updated.secretRef == null);
      _forget(removed);
    });
  }

  Future<void> _delete(SshProfile profile) async {
    final approved = await sshConfirm(
      context,
      l,
      l.text('Delete connection?', 'Удалить подключение?'),
      l.delete,
      content: Text(profile.name),
    );
    if (!mounted || !approved) return;
    await _update(() async {
      _forget(await _repository.delete(profile.id));
    });
  }

  Future<void> _newGroup() async {
    final group =
        await sshTextDialog(context, l, l.text('New group', 'Новая группа'));
    if (!mounted || group == null) return;
    await _update(() => _repository.addGroup(group));
  }

  Future<void> _update(Future<void> Function() operation) async {
    try {
      await operation();
      if (mounted) await _load();
    } catch (_) {
      _notice(l.text(
          'Could not save SSH settings', 'Не удалось сохранить настройки SSH'));
    }
  }

  void _notice(String message) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger != null) {
      messenger.showSnackBar(SnackBar(content: Text(message)));
    }
  }

  void _forget(String? reference, {bool notify = true}) {
    if (reference == null) return;
    try {
      if (_secrets.delete(reference)) return;
    } catch (_) {
      // The provider can be unavailable in the current Windows logon session.
    }
    if (notify) {
      _notice(l.text('Could not remove the saved credential',
          'Не удалось удалить сохранённые данные'));
    }
  }

  SshProfile _latest(SshProfile profile) =>
      _profiles.where((candidate) => candidate.id == profile.id).firstOrNull ??
      profile;

  Future<SshCredential?> _credential(SshTab tab, Future<void> ended,
      {required bool privateKey}) async {
    if (!mounted) return null;
    final profile = tab.profile;
    final current = _latest(profile);
    SshCredential? saved;
    if (current.endpoint == profile.endpoint &&
        current.username == profile.username &&
        current.auth == profile.auth &&
        current.secretRef != null) {
      try {
        final raw = _secrets.read(current.secretRef!);
        if (raw != null) {
          final data = jsonDecode(raw) as Map<String, dynamic>;
          saved = (
            secret: data['secret'] as String,
            keyPath: data['keyPath'] as String?,
            remember: false
          );
        }
      } catch (_) {
        // The form still permits a credential for this connection.
      }
    }
    final credentials = await sshDialog<SshCredential>(
        context,
        (_) => SshCredentialDialog(
              labels: l,
              destination: '${profile.username}@${profile.endpoint}',
              privateKey: privateKey,
              canPersist: _secrets.canPersist,
              saved: saved,
            ),
        ended: ended);
    if (credentials != null && credentials.remember) {
      unawaited(_remember(profile, credentials));
    }
    return credentials;
  }

  Future<void> _remember(SshProfile profile, SshCredential credential) async {
    final reference = const Uuid().v4();
    try {
      final value = jsonEncode(
          {'secret': credential.secret, 'keyPath': credential.keyPath});
      if (!_secrets.write(reference, value)) {
        _notice(l.text(
            'Secure storage unavailable. Credential used for this connection only.',
            'Защищённое хранилище недоступно. Данные используются только для этого подключения.'));
        return;
      }
      final result = await _repository.attachSecret(profile, reference);
      if (result.saved) {
        _forget(result.previous);
        if (mounted) await _load();
      } else {
        _forget(reference, notify: false);
      }
    } catch (_) {
      _forget(reference, notify: false);
      _notice(l.text('Could not save the credential',
          'Не удалось сохранить учётные данные'));
    }
  }

  Future<List<String>?> _challenge(
      SshTab tab, SSHUserInfoRequest request, Future<void> ended) {
    if (!mounted || request.prompts.length > 24) return Future.value();
    final responses = List.filled(request.prompts.length, '');
    return sshDialog(
        context,
        (context) => AlertDialog(
              title: Text(l.keyboardInteractive),
              content: SizedBox(
                width: 440,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${tab.profile.username}@${tab.profile.endpoint}'),
                      if (request.instruction.isNotEmpty)
                        Text(request.instruction,
                            maxLines: 8, overflow: TextOverflow.ellipsis),
                      for (final (index, prompt) in request.prompts.indexed)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: TextField(
                            autofocus: index == 0,
                            obscureText: !prompt.echo,
                            enableSuggestions: false,
                            autocorrect: false,
                            decoration: InputDecoration(
                              label: Text(prompt.promptText,
                                  maxLines: 2, overflow: TextOverflow.ellipsis),
                            ),
                            onChanged: (value) => responses[index] = value,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(l.cancel)),
                FilledButton(
                    onPressed: () => Navigator.pop(context, responses),
                    child: Text(l.connect)),
              ],
            ),
        ended: ended);
  }

  void _connect(SshTab tab) {
    tab.connect(SshPrompts(
      verify: (key, ended) async =>
          mounted &&
          await sshConfirm(
            context,
            l,
            l.text('Trust this SSH server?', 'Доверять этому SSH-серверу?'),
            l.text('Trust and save', 'Доверять и сохранить'),
            content: SizedBox(
              width: 440,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l.text(
                      'Verify the fingerprint with the server administrator.',
                      'Сверьте отпечаток с администратором сервера.')),
                  const SizedBox(height: 12),
                  SelectableText(
                      '${tab.profile.endpoint}\n${key.algorithm}\n${key.fingerprint}'),
                ],
              ),
            ),
            ended: ended,
          ),
      password: (ended) async =>
          (await _credential(tab, ended, privateKey: false))?.secret,
      privateKey: (ended) async {
        final credential = await _credential(tab, ended, privateKey: true);
        final path = credential?.keyPath;
        if (credential == null || path == null) return null;
        return (
          path: path,
          passphrase: credential.secret.isEmpty ? null : credential.secret
        );
      },
      challenge: (request, ended) => _challenge(tab, request, ended),
    ));
  }

  void _open(SshProfile profile) {
    final tab = SshTab(profile, _repository);
    setState(() {
      _tabs.add(tab);
      _current = tab;
      _showProfiles = false;
    });
    _connect(tab);
  }

  Future<void> _close(SshTab tab) async {
    if (tab.busy &&
        !await sshConfirm(context, l,
            l.text('Close this SSH session?', 'Закрыть SSH-сессию?'), l.close,
            content: Text(tab.title))) {
      return;
    }
    if (!mounted || !_tabs.contains(tab)) return;
    setState(() {
      final index = _tabs.indexOf(tab);
      _tabs.removeAt(index);
      if (_current == tab) {
        _current =
            _tabs.isEmpty ? null : _tabs[index.clamp(0, _tabs.length - 1)];
      }
      if (_tabs.isEmpty) _showProfiles = true;
    });
    tab.dispose();
  }

  Future<void> _rename(SshTab tab) async {
    final title = await sshTextDialog(
        context, l, l.text('Rename tab', 'Переименовать вкладку'),
        initialValue: tab.title);
    if (mounted && title != null && _tabs.contains(tab)) tab.rename(title);
  }

  Iterable<SshProfile> get _filtered {
    final query = _query.trim().toLowerCase();
    return _profiles.where((profile) =>
        (!_favorites || profile.favorite) &&
        [
          profile.name,
          profile.host,
          profile.username,
          profile.comment,
          profile.group
        ].any((value) => value.toLowerCase().contains(query)));
  }

  Widget _profileTile(SshProfile profile) => ListTile(
        dense: true,
        leading:
            profile.favorite ? const Icon(Icons.star_outline, size: 18) : null,
        title: Text(profile.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text('${profile.username}@${profile.endpoint}',
            maxLines: 1, overflow: TextOverflow.ellipsis),
        onTap: () => _open(profile),
        trailing: PopupMenuButton<String>(
          tooltip: l.text('Connection actions', 'Действия подключения'),
          onSelected: (action) {
            if (action == 'edit') unawaited(_edit(profile));
            if (action == 'delete') unawaited(_delete(profile));
            if (action == 'favorite') {
              unawaited(_update(() =>
                  _repository.setFavorite(profile.id, !profile.favorite)));
            }
          },
          itemBuilder: (_) => [
            PopupMenuItem(value: 'edit', child: Text(l.edit)),
            PopupMenuItem(
                value: 'favorite',
                child: Text(profile.favorite
                    ? l.text('Remove from favorites', 'Убрать из избранного')
                    : l.text('Add to favorites', 'Добавить в избранное'))),
            PopupMenuItem(value: 'delete', child: Text(l.delete)),
          ],
        ),
      );

  Widget _catalog() {
    final filtered = _filtered.toList();
    return Material(
      color: YesDeskColors.of(context).surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(YesDeskSpace.sm),
            child: TextField(
              onChanged: (value) => setState(() => _query = value),
              decoration: InputDecoration(
                labelText: l.text('Search servers', 'Поиск серверов'),
                prefixIcon: const Icon(Icons.search, size: 18),
              ),
            ),
          ),
          Wrap(
            children: [
              YesDeskIconButton(
                label: l.text('New connection', 'Новое подключение'),
                icon: Icons.add,
                onPressed: _loading || _loadFailed ? null : _edit,
              ),
              YesDeskIconButton(
                label: l.text('New group', 'Новая группа'),
                icon: Icons.create_new_folder_outlined,
                onPressed: _loading || _loadFailed ? null : _newGroup,
              ),
              YesDeskIconButton(
                label: l.favorite,
                icon: Icons.star_outline,
                selected: _favorites,
                onPressed: () => setState(() => _favorites = !_favorites),
              ),
            ],
          ),
          const Divider(height: 1),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _loadFailed
                    ? Center(
                        child: TextButton(
                        onPressed: _load,
                        child: Text(l.text('Could not load servers. Retry',
                            'Не удалось загрузить серверы. Повторить')),
                      ))
                    : ListView(
                        children: [
                          for (final profile in filtered
                              .where((profile) => profile.group.isEmpty))
                            _profileTile(profile),
                          for (final group in _groups)
                            if (_query.isEmpty && !_favorites ||
                                filtered
                                    .any((profile) => profile.group == group))
                              ExpansionTile(
                                key: PageStorageKey(group),
                                leading:
                                    const Icon(Icons.folder_outlined, size: 18),
                                title: Text(group),
                                initiallyExpanded: true,
                                children: [
                                  for (final profile in filtered.where(
                                      (profile) => profile.group == group))
                                    _profileTile(profile),
                                ],
                              ),
                        ],
                      ),
          ),
        ],
      ),
    );
  }

  Future<void> _additionalSession() async {
    if (_profiles.isEmpty) {
      await _edit();
      return;
    }
    final profile = await sshDialog<SshProfile>(
        context,
        (context) => AlertDialog(
              title: Text(l.text('New SSH session', 'Новая SSH-сессия')),
              content: SizedBox(
                width: 380,
                height: 250,
                child: ListView.builder(
                  itemCount: _profiles.length,
                  itemBuilder: (_, index) {
                    final profile = _profiles[index];
                    return ListTile(
                      title: Text(profile.name),
                      subtitle: Text(profile.endpoint),
                      onTap: () => Navigator.pop(context, profile),
                    );
                  },
                ),
              ),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(l.cancel))
              ],
            ));
    if (mounted && profile != null) _open(profile);
  }

  Future<void> _forgetHostKey(SshTab tab, SshHostKey expected) async {
    final approved = await sshConfirm(
      context,
      l,
      l.text('Forget the saved host key?', 'Забыть сохранённый ключ сервера?'),
      l.text('Forget key', 'Забыть ключ'),
      content: Text(l.text(
        'Confirm the server key change with your administrator. You will need to verify the fingerprint on the next connection.',
        'Подтвердите смену ключа у администратора. При следующем подключении потребуется сверить отпечаток.',
      )),
    );
    if (!mounted || !approved) return;
    try {
      final removed =
          await _repository.removeTrust(tab.profile.endpoint, expected);
      _notice(removed
          ? l.text('Saved key removed', 'Сохранённый ключ удалён')
          : l.text('Saved key has already changed',
              'Сохранённый ключ уже изменился'));
    } catch (_) {
      _notice(l.text(
          'Could not remove the host key', 'Не удалось удалить ключ сервера'));
    }
  }

  String _status(SshTab tab) => switch (tab.phase) {
        SshPhase.idle => l.text('Ready', 'Готово'),
        SshPhase.connecting => l.text('Connecting…', 'Подключение…'),
        SshPhase.verifyingHost =>
          l.text('Verifying host key…', 'Проверка ключа сервера…'),
        SshPhase.authenticating => l.text('Authenticating…', 'Аутентификация…'),
        SshPhase.active => l.text('Connected', 'Подключено'),
        SshPhase.closing => l.text('Closing…', 'Завершение…'),
        SshPhase.closed => l.text('Session closed', 'Сессия закрыта'),
        SshPhase.failed => switch (tab.run?.failure) {
            SshFailure.timeout =>
              l.text('Connection timed out', 'Время ожидания истекло'),
            SshFailure.unavailable =>
              l.text('Server unavailable', 'Сервер недоступен'),
            SshFailure.rejected =>
              l.text('Host key declined', 'Ключ сервера отклонён'),
            SshFailure.changedKey => l.text(
                'Host key changed. Connection blocked.',
                'Ключ сервера изменился. Подключение заблокировано.'),
            SshFailure.authentication =>
              l.text('Authentication failed', 'Ошибка аутентификации'),
            SshFailure.privateKey => l.text(
                'Could not read or unlock the private key',
                'Не удалось прочитать или расшифровать приватный ключ'),
            SshFailure.disconnected =>
              l.text('Connection lost', 'Соединение потеряно'),
            SshFailure.storage => l.text('Could not verify saved host keys',
                'Не удалось проверить сохранённые ключи серверов'),
            _ => l.text('SSH negotiation or shell setup failed',
                'Ошибка согласования SSH или запуска оболочки'),
          },
      };

  Widget _session(SshTab tab) => ListenableBuilder(
        key: ObjectKey(tab),
        listenable: tab,
        builder: (context, _) {
          final expected = tab.run?.expectedKey;
          final received = tab.run?.receivedKey;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Semantics(
                      liveRegion: true,
                      child: Text(_status(tab),
                          style: TextStyle(
                            color: tab.phase == SshPhase.failed
                                ? YesDeskColors.of(context).error
                                : null,
                          )),
                    ),
                  ),
                  if (tab.phase == SshPhase.active)
                    YesDeskIconButton(
                      label: l.text('Disconnect', 'Отключить'),
                      icon: Icons.link_off,
                      onPressed: () async {
                        final run = tab.run;
                        if (await sshConfirm(
                              context,
                              l,
                              l.text('Disconnect this SSH session?',
                                  'Отключить SSH-сессию?'),
                              l.text('Disconnect', 'Отключить'),
                            ) &&
                            mounted &&
                            tab.run == run) {
                          run?.cancel();
                        }
                      },
                    )
                  else if (tab.busy)
                    TextButton(
                        onPressed: tab.run?.cancel, child: Text(l.cancel))
                  else
                    TextButton(
                        onPressed: () => _connect(tab),
                        child: Text(l.text('Reconnect', 'Переподключить'))),
                ],
              ),
              if (expected != null && received != null)
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SelectableText(
                        '${l.text('Saved key', 'Сохранённый ключ')}  ${expected.algorithm} ${expected.fingerprint}\n'
                        '${l.text('Received key', 'Полученный ключ')}  ${received.algorithm} ${received.fingerprint}',
                      ),
                      TextButton(
                        onPressed: () => _forgetHostKey(tab, expected),
                        child: Text(l.text(
                            'Forget saved key…', 'Забыть сохранённый ключ…')),
                      ),
                    ],
                  ),
                ),
              Expanded(child: SshTerminalView(tab: tab, labels: l)),
            ],
          );
        },
      );

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, bounds) {
      final wide = bounds.maxWidth >= 660;
      final showCatalog = wide || _showProfiles;
      final showTerminal = wide || !_showProfiles;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (!wide && _tabs.isNotEmpty)
                YesDeskIconButton(
                  label: l.text('Saved servers', 'Сохранённые серверы'),
                  icon: Icons.list,
                  selected: _showProfiles,
                  onPressed: () =>
                      setState(() => _showProfiles = !_showProfiles),
                ),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(children: [
                    if (_tabs.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Text(l.title,
                            style: Theme.of(context).textTheme.titleMedium),
                      ),
                    for (final tab in _tabs)
                      ListenableBuilder(
                        listenable: tab,
                        builder: (_, __) => Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            TextButton(
                              style: TextButton.styleFrom(
                                backgroundColor: tab == _current
                                    ? YesDeskColors.of(context).selected
                                    : null,
                              ),
                              onPressed: () => setState(() {
                                _current = tab;
                                _showProfiles = false;
                              }),
                              child: Text(tab.title,
                                  overflow: TextOverflow.ellipsis),
                            ),
                            YesDeskIconButton(
                                label: l.text(
                                    'Rename tab', 'Переименовать вкладку'),
                                icon: Icons.edit_outlined,
                                onPressed: () => _rename(tab)),
                            YesDeskIconButton(
                                label: l.text('Close tab', 'Закрыть вкладку'),
                                icon: Icons.close,
                                onPressed: () => _close(tab)),
                          ],
                        ),
                      ),
                  ]),
                ),
              ),
              YesDeskIconButton(
                label: l.text('New SSH session', 'Новая SSH-сессия'),
                icon: Icons.add,
                onPressed: _loading || _loadFailed ? null : _additionalSession,
              ),
            ],
          ),
          const Divider(height: 1),
          Expanded(
            child: Stack(
              children: [
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  width: wide ? 236 : bounds.maxWidth,
                  child: Visibility(
                      visible: showCatalog,
                      maintainState: true,
                      child: _catalog()),
                ),
                if (wide)
                  const Positioned(
                      left: 236,
                      top: 0,
                      bottom: 0,
                      child: VerticalDivider(width: 1)),
                Positioned.fill(
                  left: wide ? 237 : 0,
                  child: Visibility(
                    visible: showTerminal,
                    maintainState: true,
                    child: _current == null
                        ? Center(
                            child: Text(l.text('Choose a saved server',
                                'Выберите сохранённый сервер')))
                        : IndexedStack(
                            index: _tabs.indexOf(_current!),
                            children: [
                              for (final tab in _tabs)
                                ExcludeFocus(
                                  key: ObjectKey(tab),
                                  excluding: tab != _current || !showTerminal,
                                  child: _session(tab),
                                ),
                            ],
                          ),
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    });
  }
}
