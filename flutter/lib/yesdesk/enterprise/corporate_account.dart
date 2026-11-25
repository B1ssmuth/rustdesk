import 'package:flutter/material.dart';

import 'corporate_session.dart';

class CorporateAccount extends StatefulWidget {
  const CorporateAccount({super.key});

  @override
  State<CorporateAccount> createState() => _CorporateAccountState();
}

class _CorporateAccountState extends State<CorporateAccount> {
  bool _failed = false;
  bool _logoutFailed = false;
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _code = TextEditingController();

  Future<void> _changePassword(bool ru) async {
    String t(String en, String russian) => ru ? russian : en;
    var previous = '';
    var replacement = '';
    final submitted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t('Change password', 'Сменить пароль')),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              onChanged: (value) => previous = value,
              decoration: InputDecoration(
                  labelText: t('Current password', 'Текущий пароль'))),
          TextField(
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              onChanged: (value) => replacement = value,
              decoration: InputDecoration(
                  labelText: t('New password (14+ characters)',
                      'Новый пароль (от 14 символов)'))),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(t('Cancel', 'Отмена'))),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(t('Save', 'Сохранить'))),
        ],
      ),
    );
    if (submitted != true || !mounted) return;
    try {
      await corporateSession.api('/v2/auth/password',
          method: 'PUT',
          body: {'current': previous, 'replacement': replacement});
      await corporateSession.signOut();
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(t(
                  'Could not change password.', 'Не удалось сменить пароль.'))),
        );
    }
  }

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ru = Localizations.localeOf(context).languageCode == 'ru';
    String t(String en, String russian) => ru ? russian : en;
    return ListenableBuilder(
      listenable: corporateSession,
      builder: (context, _) {
        final profile = corporateSession.profile;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (profile == null) ...[
              Text(t('Remote access works without a corporate account.',
                  'Удалённый доступ работает без корпоративного аккаунта.')),
              if (!corporateSession.configured)
                Text(t('Corporate sign-in is unconfigured.',
                    'Корпоративный вход не настроен.')),
              if (_logoutFailed)
                Text(t('Signed out locally. Server revocation was unavailable.',
                    'Локальный выход выполнен. Серверный отзыв недоступен.')),
              if (corporateSession.configured) ...[
                TextField(
                    controller: _username,
                    decoration:
                        InputDecoration(labelText: t('Login', 'Логин'))),
                TextField(
                    controller: _password,
                    obscureText: true,
                    enableSuggestions: false,
                    autocorrect: false,
                    decoration:
                        InputDecoration(labelText: t('Password', 'Пароль'))),
                TextField(
                    controller: _code,
                    keyboardType: TextInputType.number,
                    maxLength: 6,
                    decoration:
                        InputDecoration(labelText: t('MFA code', 'Код MFA'))),
              ],
              OutlinedButton(
                onPressed:
                    corporateSession.configured && !corporateSession.signingIn
                        ? () async {
                            setState(() => _failed = false);
                            try {
                              await corporateSession.signIn(
                                  _username.text, _password.text, _code.text);
                            } catch (_) {
                              if (mounted) setState(() => _failed = true);
                            } finally {
                              if (mounted) {
                                _password.clear();
                                _code.clear();
                              }
                            }
                          }
                        : null,
                child: Text(t('Sign in with corporate account',
                    'Войти через корпоративную учётную запись')),
              ),
              if (_failed)
                Text(t('Corporate sign-in failed.',
                    'Не удалось войти в корпоративный аккаунт.')),
            ] else ...[
              Text('${profile['display_name']} • ${profile['username']}'),
              Text('${profile['organization']}'),
              Text(switch (profile['role']) {
                'admin' => t('Administrator', 'Администратор'),
                'support' => t('Support', 'Специалист поддержки'),
                _ => t('Employee', 'Сотрудник'),
              }),
              Text(t('Session expires', 'Сеанс действителен до') +
                  ' ${DateTime.fromMillisecondsSinceEpoch((profile['expires_at'] as int) * 1000)}'),
              Wrap(
                spacing: 8,
                children: [
                  OutlinedButton(
                      onPressed: () => _changePassword(ru),
                      child: Text(t('Change password', 'Сменить пароль'))),
                  OutlinedButton(
                    onPressed: () async {
                      setState(() => _logoutFailed = false);
                      try {
                        await corporateSession.signOut();
                      } catch (_) {
                        if (mounted) setState(() => _logoutFailed = true);
                      }
                    },
                    child: Text(t('Sign out', 'Выйти')),
                  ),
                  if (corporateSession.canReadDirectory)
                    OutlinedButton(
                      onPressed: () => showDialog<void>(
                        context: context,
                        builder: (_) => _Directory(ru: ru),
                      ),
                      child: Text(
                          t('Workplace directory', 'Каталог рабочих мест')),
                    ),
                ],
              ),
            ],
          ],
        );
      },
    );
  }
}

class _Directory extends StatefulWidget {
  const _Directory({required this.ru});
  final bool ru;

  @override
  State<_Directory> createState() => _DirectoryState();
}

class _DirectoryState extends State<_Directory> {
  final _search = TextEditingController();
  late Future<dynamic> _result;
  String? _notice;
  bool _requestPending = false;
  int _offset = 0;

  String t(String en, String ru) => widget.ru ? ru : en;

  @override
  void initState() {
    super.initState();
    _result = _searchDirectory();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<dynamic> _searchDirectory() => corporateSession.api('/v2/devices',
      query: {'q': _search.text.trim(), 'offset': '$_offset'});

  void _reload({int offset = 0}) => setState(() {
        _offset = offset;
        _notice = null;
        _result = _searchDirectory();
      });

  Future<void> _connect(String id) async {
    if (_requestPending) return;
    setState(() {
      _requestPending = true;
      _notice = null;
    });
    try {
      await corporateSession.api('/v2/devices/$id/connection', method: 'POST');
      if (mounted) {
        setState(
            () => _notice = t('No session was started.', 'Сеанс не запущен.'));
      }
    } on CorporateApiError catch (error) {
      if (!mounted) return;
      setState(() => _notice = switch (error.statusCode) {
            501 => t('The endpoint cannot verify corporate access yet.',
                'Компьютер пока не может проверить корпоративный доступ.'),
            401 => t('Sign in again to continue.', 'Войдите снова.'),
            403 => t('Access denied or device unavailable.',
                'Доступ запрещён или компьютер недоступен.'),
            _ => t('Management API unavailable.', 'Management API недоступен.'),
          });
    } catch (_) {
      if (mounted) {
        setState(() => _notice =
            t('Management API unavailable.', 'Management API недоступен.'));
      }
    } finally {
      if (mounted) setState(() => _requestPending = false);
    }
  }

  Future<void> _save(
      Map<String, dynamic> row, bool favorite, String group) async {
    try {
      await corporateSession.api('/v2/devices/${row['id']}/preferences',
          method: 'PUT', body: {'favorite': favorite, 'group_name': group});
      if (mounted) _reload();
    } catch (_) {
      if (mounted)
        setState(() => _notice = t('Could not save device preferences.',
            'Не удалось сохранить настройки устройства.'));
    }
  }

  void _showHistory(Map<String, dynamic> row) {
    final future = corporateSession.api('/v2/devices/${row['id']}/history');
    var group = row['group_name'] as String;
    showDialog<void>(
      context: context,
      builder: (context) => ListenableBuilder(
        listenable: corporateSession,
        builder: (context, _) => AlertDialog(
          title: Text('${row['hostname']}'),
          content: SizedBox(
              width: 510,
              height: 390,
              child: !corporateSession.canReadDirectory
                  ? Text(t('Directory access has expired.',
                      'Доступ к каталогу истёк.'))
                  : Column(children: [
                      TextField(
                          maxLength: 80,
                          onChanged: (value) => group = value,
                          decoration: InputDecoration(
                              hintText: group,
                              labelText:
                                  t('Device group', 'Группа устройств'))),
                      Expanded(
                          child: FutureBuilder<dynamic>(
                        future: future,
                        builder: (context, snapshot) {
                          if (snapshot.hasError)
                            return Text(t(
                                'History unavailable.', 'История недоступна.'));
                          if (!snapshot.hasData)
                            return const Center(
                                child: CircularProgressIndicator());
                          final history = snapshot.data as List;
                          if (history.isEmpty)
                            return Text(t('No confirmed sessions.',
                                'Подтверждённых сеансов нет.'));
                          return ListView(children: [
                            for (final event in history)
                              ListTile(
                                  title: Text(
                                      '${event['username']} · ${event['transport']}'),
                                  subtitle: Text(
                                      '${event['observed_at']} · ${event['kind']}'),
                                  trailing: event['current'] == true
                                      ? const Icon(Icons.person)
                                      : null),
                          ]);
                        },
                      )),
                    ])),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(t('Close', 'Закрыть'))),
            if (corporateSession.canReadDirectory)
              TextButton(
                  onPressed: () {
                    Navigator.pop(context);
                    _save(row, row['favorite'] == true, group);
                  },
                  child: Text(t('Save group', 'Сохранить группу'))),
          ],
        ),
      ),
    );
  }

  ListTile _device(Map<String, dynamic> row) {
    final heartbeat = DateTime.tryParse('${row['last_heartbeat']}')?.toLocal();
    final age = heartbeat == null ? null : DateTime.now().difference(heartbeat);
    final fresh =
        age != null && !age.isNegative && age < const Duration(minutes: 2);
    final hardware = row['metadata'] as Map<String, dynamic>? ?? {};
    final detail = [
      '${row['dns_name']} · ID ${row['yesdesk_id']}',
      if ((row['group_name'] as String).isNotEmpty) row['group_name'] as String,
      fresh
          ? t('Recent agent heartbeat', 'Свежая связь с агентом')
          : t('Agent status unconfirmed', 'Состояние агента не подтверждено'),
      if (heartbeat != null) '${t('Heartbeat', 'Последняя связь')} $heartbeat',
      for (final key in ['domain', 'os', 'model', 'cpu'])
        if (hardware[key] != null && hardware[key] != '') '${hardware[key]}',
      if (hardware['ram_bytes'] case final int bytes)
        'RAM ${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GiB',
      if (hardware['disks'] case final List disks)
        for (final disk in disks)
          '${disk['name']} ${(disk['bytes'] / (1024 * 1024 * 1024)).toStringAsFixed(1)} GiB',
    ];
    return ListTile(
      onTap: () => _showHistory(row),
      leading: IconButton(
        tooltip: t('Favorite', 'Избранное'),
        onPressed: () =>
            _save(row, row['favorite'] != true, row['group_name'] as String),
        icon: Icon(row['favorite'] == true ? Icons.star : Icons.star_border),
      ),
      title: Text('${row['hostname']}'),
      subtitle: Text(detail.join('\n')),
      trailing: row['can_request_consent'] == true && fresh
          ? TextButton(
              onPressed:
                  _requestPending ? null : () => _connect(row['id'] as String),
              child: Text(t('Request connection', 'Запросить подключение')),
            )
          : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: corporateSession,
      builder: (context, _) => AlertDialog(
        title: Text(t('Workplace directory', 'Каталог рабочих мест')),
        content: SizedBox(
          width: 620,
          height: 475,
          child: !corporateSession.canReadDirectory
              ? Text(t(
                  'Directory access has expired.', 'Доступ к каталогу истёк.'))
              : Column(
                  children: [
                    TextField(
                      controller: _search,
                      maxLength: 100,
                      onSubmitted: (_) => _reload(),
                      decoration: InputDecoration(
                        labelText: t('Computer, username or ID',
                            'ПК, пользователь или ID'),
                        suffixIcon: IconButton(
                            onPressed: () => _reload(),
                            icon: const Icon(Icons.search)),
                      ),
                    ),
                    if (_notice != null) Text(_notice!),
                    Expanded(
                      child: FutureBuilder<dynamic>(
                        future: _result,
                        builder: (context, snapshot) {
                          if (snapshot.connectionState !=
                              ConnectionState.done) {
                            return const Center(
                                child: CircularProgressIndicator());
                          }
                          if (snapshot.hasError) {
                            return Text(t('Directory unavailable.',
                                'Каталог недоступен.'));
                          }

                          final rows = snapshot.data as List;
                          return Column(children: [
                            Expanded(
                                child: rows.isEmpty
                                    ? Text(t('No results.', 'Нет результатов.'))
                                    : ListView.builder(
                                        itemCount: rows.length,
                                        itemBuilder: (context, index) =>
                                            _device(rows[index]
                                                as Map<String, dynamic>),
                                      )),
                            if (_offset > 0 || rows.length == 100)
                              Wrap(children: [
                                TextButton(
                                  onPressed: _offset == 0
                                      ? null
                                      : () => _reload(offset: _offset - 100),
                                  child: Text(t('Previous', 'Назад')),
                                ),
                                TextButton(
                                  onPressed: rows.length != 100
                                      ? null
                                      : () => _reload(offset: _offset + 100),
                                  child: Text(t('Next', 'Далее')),
                                ),
                              ]),
                          ]);
                        },
                      ),
                    ),
                  ],
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(t('Close', 'Закрыть')),
          ),
        ],
      ),
    );
  }
}
