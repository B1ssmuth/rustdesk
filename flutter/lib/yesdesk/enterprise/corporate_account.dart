import 'package:flutter/material.dart';

import 'admin_users.dart';
import 'corporate_session.dart';

class CorporateAccount extends StatefulWidget {
  const CorporateAccount({super.key});

  @override
  State<CorporateAccount> createState() => _CorporateAccountState();
}

class _CorporateAccountState extends State<CorporateAccount> {
  String? _loginError;
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
                            setState(() => _loginError = null);
                            try {
                              await corporateSession.signIn(
                                  _username.text, _password.text, _code.text);
                            } catch (error) {
                              if (mounted)
                                setState(() => _loginError = switch (error) {
                                      CorporateApiError(statusCode: 401) => t(
                                          'Invalid login, password or TOTP.',
                                          'Неверный логин, пароль или TOTP.'),
                                      CorporateApiError(statusCode: 403) =>
                                        t('Access denied.', 'Доступ запрещён.'),
                                      CorporateApiError(statusCode: 429) => t(
                                          'Too many attempts. Try again later.',
                                          'Слишком много попыток. Повторите позже.'),
                                      _ => t('Corporate sign-in failed.',
                                          'Не удалось войти в корпоративный аккаунт.'),
                                    });
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
              if (_loginError != null) Text(_loginError!),
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
                  if (corporateSession.isAdmin)
                    OutlinedButton(
                      onPressed: () => showDialog<void>(
                          context: context, builder: (_) => AdminUsers(ru: ru)),
                      child: Text(t('Administration → Users',
                          'Администрирование → Пользователи')),
                    ),
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
                      Text(
                          '${row['dns_name']} · ${row['yesdesk_id']} · ${_status(row)}'),
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
            if (row['can_request_consent'] == true)
              TextButton(
                  onPressed: _requestPending
                      ? null
                      : () {
                          Navigator.pop(context);
                          _connect(row['id'] as String);
                        },
                  child: Text(
                      t('Check access policy', 'Проверить политику доступа'))),
            if (corporateSession.canReadDirectory &&
                row['agent_registered'] == true)
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

  String _field(Object? value) => value?.toString() ?? '—';

  String _status(Map<String, dynamic> row) {
    if (row['agent_registered'] != true)
      return t('Agent missing', 'Агент отсутствует');
    final heartbeat = DateTime.tryParse(_field(row['last_heartbeat']));
    final age = heartbeat == null ? null : DateTime.now().difference(heartbeat);
    return age != null && !age.isNegative && age < const Duration(minutes: 2)
        ? t('Online', 'В сети')
        : t('Offline', 'Не в сети');
  }

  Widget _table(List rows) => SingleChildScrollView(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            showCheckboxColumn: false,
            columnSpacing: 20,
            columns: [
              const DataColumn(label: Icon(Icons.star_outline)),
              DataColumn(label: Text(t('Computer', 'Компьютер'))),
              DataColumn(label: Text(t('Agent status', 'Статус агента'))),
              DataColumn(
                  label: Text(t('Windows user', 'Пользователь Windows'))),
              const DataColumn(label: Text('YES Desk ID')),
              DataColumn(label: Text(t('OS', 'ОС'))),
              const DataColumn(label: Text('CPU')),
              const DataColumn(label: Text('RAM')),
              DataColumn(
                  label: Text(t('Last heartbeat', 'Последний heartbeat'))),
              DataColumn(label: Text(t('Group', 'Группа'))),
            ],
            rows: [
              for (final Map<String, dynamic> row in rows) _device(row),
            ],
          ),
        ),
      );

  DataRow _device(Map<String, dynamic> row) {
    final hardware = row['metadata'] as Map<String, dynamic>;
    final favorite = row['favorite'] == true;
    final ram = hardware['ram_bytes'] as int?;
    final time = DateTime.tryParse(_field(row['last_heartbeat']))?.toLocal();
    return DataRow(
      onSelectChanged: (_) => _showHistory(row),
      cells: [
        DataCell(IconButton(
            tooltip: t('Favorite', 'Избранное'),
            icon: Icon(favorite ? Icons.star : Icons.star_border),
            onPressed: row['agent_registered'] == true
                ? () => _save(row, !favorite, row['group_name'] as String)
                : null)),
        DataCell(Text(_field(row['hostname']))),
        DataCell(Text(_status(row))),
        DataCell(Text(_field(row['windows_user']))),
        DataCell(Text(_field(row['yesdesk_id']))),
        DataCell(Text(_field(hardware['os']))),
        DataCell(Text(_field(hardware['cpu']))),
        DataCell(Text(
            ram == null ? '—' : '${(ram / (1 << 30)).toStringAsFixed(1)} GiB')),
        DataCell(Text(_field(time))),
        DataCell(Text(_field(row['group_name']))),
      ],
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
                    Text(t('Corporate connection unavailable.',
                        'Корпоративное подключение недоступно.')),
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
                          if (snapshot.error
                              case CorporateApiError(statusCode: 401 || 403)) {
                            return Text(t('Access denied or session expired.',
                                'Доступ запрещён или сеанс истёк.'));
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
                                    : _table(rows)),
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
