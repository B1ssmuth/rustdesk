import 'package:flutter/material.dart';

import 'corporate_session.dart';

class AdminUsers extends StatefulWidget {
  const AdminUsers({super.key, required this.ru});
  final bool ru;

  @override
  State<AdminUsers> createState() => _AdminUsersState();
}

class _AdminUsersState extends State<AdminUsers> {
  final _search = TextEditingController();
  int _offset = 0;
  bool _busy = false;
  String? _notice;
  late Future<dynamic> _rows;

  String t(String en, String ru) => widget.ru ? ru : en;

  @override
  void initState() {
    super.initState();
    if (corporateSession.isAdmin) {
      _fetch();
    } else {
      _rows = Future.value(const []);
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _fetch() {
    _rows = corporateSession.api('/v2/accounts',
        query: {'q': _search.text.trim(), 'offset': '$_offset'});
  }

  String _error(Object error) => switch (error) {
        CorporateApiError(statusCode: 401) => t(
            'Session or verification code invalid.',
            'Сеанс или код проверки недействителен.'),
        CorporateApiError(statusCode: 403) =>
          t('Administrator required.', 'Требуются права администратора.'),
        CorporateApiError(statusCode: 409) => t(
            'Conflict. Keep an enabled administrator with MFA.',
            'Конфликт. Сохраните хотя бы одного активного администратора с MFA.'),
        CorporateApiError(statusCode: 422) =>
          t('Check the supplied fields.', 'Проверьте заполненные поля.'),
        CorporateApiError(statusCode: 429) => t(
            'Too many attempts. Try again later.',
            'Слишком много попыток. Повторите позже.'),
        _ => t('Management API unavailable.', 'Management API недоступен.'),
      };

  Future<void> _save(String path, String method,
      {Map<String, dynamic>? body, String? success}) async {
    if (_busy || !corporateSession.isAdmin) return;
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      await corporateSession.api(path, method: method, body: body);
      if (mounted)
        setState(() {
          _notice = success;
          _fetch();
        });
    } catch (error) {
      if (mounted) setState(() => _notice = _error(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit([Map<String, dynamic>? row]) async {
    var username = row?['username'] as String? ?? '';
    var name = row?['display_name'] as String? ?? '';
    var role = row?['role'] as String? ?? 'user';
    var password = '';
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(builder: (context, update) {
        return AlertDialog(
          title: Text(row == null
              ? t('Create user', 'Создать пользователя')
              : t('Edit user', 'Изменить пользователя')),
          content: SingleChildScrollView(
              child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                  initialValue: username,
                  enabled: row == null,
                  maxLength: 64,
                  onChanged: (v) => username = v,
                  decoration: InputDecoration(labelText: t('Login', 'Логин'))),
              TextFormField(
                  initialValue: name,
                  maxLength: 128,
                  onChanged: (v) => name = v,
                  decoration: InputDecoration(
                      labelText: t('Display name', 'Отображаемое имя'))),
              DropdownButtonFormField<String>(
                  value: role,
                  decoration: InputDecoration(labelText: t('Role', 'Роль')),
                  items: ['admin', 'support', 'user']
                      .map((value) =>
                          DropdownMenuItem(value: value, child: Text(value)))
                      .toList(),
                  onChanged: (value) => update(() => role = value!)),
              if (row == null)
                TextField(
                    obscureText: true,
                    enableSuggestions: false,
                    autocorrect: false,
                    onChanged: (v) => password = v,
                    decoration: InputDecoration(
                        labelText: t('Initial password (14+ characters)',
                            'Первоначальный пароль (от 14 символов)'))),
            ],
          )),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(t('Cancel', 'Отмена'))),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(t('Save', 'Сохранить'))),
          ],
        );
      }),
    );
    if (accepted != true || !mounted) return;
    final body = {'display_name': name.trim(), 'role': role};
    if (row == null) {
      await _save('/v2/accounts', 'POST', body: {
        ...body,
        'username': username.trim().toLowerCase(),
        'password': password
      });
    } else {
      await _save('/v2/accounts/${Uri.encodeComponent(username)}', 'PATCH',
          body: body);
    }
  }

  Future<void> _reset(String path) async {
    var password = '';
    var code = '';
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
            t('Verify administrator', 'Подтвердите личность администратора')),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(t(
              'This revokes the user’s sessions. A server operator must verify the user and re-enroll MFA.',
              'Сеансы пользователя будут отозваны. Оператор сервера должен подтвердить личность пользователя и настроить MFA заново.')),
          TextField(
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              onChanged: (v) => password = v,
              decoration:
                  InputDecoration(labelText: t('Your password', 'Ваш пароль'))),
          TextField(
              maxLength: 6,
              keyboardType: TextInputType.number,
              onChanged: (v) => code = v,
              decoration: InputDecoration(
                  labelText: t('New TOTP code', 'Новый код TOTP'))),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(t('Cancel', 'Отмена'))),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(t('Request reset', 'Запросить сброс'))),
        ],
      ),
    );
    if (accepted == true && mounted) {
      await _save('$path/request-mfa-reset', 'POST',
          body: {'password': password, 'code': code.trim()},
          success: t('Waiting for server operator.',
              'Ожидается действие оператора сервера.'));
    }
  }

  Widget _row(Map<String, dynamic> row) {
    final username = row['username'] as String;
    final path = '/v2/accounts/${Uri.encodeComponent(username)}';
    final enabled = row['enabled'] == true;
    final mfa = switch (row['mfa_state']) {
      'configured' => t('Configured', 'Настроена'),
      'setup_required' => t('Setup required', 'Требуется настройка'),
      'reset_pending' => t('Reset pending', 'Ожидается сброс'),
      _ => t('Optional', 'Не обязательна'),
    };
    return ListTile(
      title: Text('${row['display_name']} · $username'),
      subtitle: Text(
          '${row['role']} · ${enabled ? t('Enabled', 'Активна') : t('Blocked', 'Заблокирована')} · MFA $mfa'),
      trailing: PopupMenuButton<String>(
        enabled: !_busy,
        itemBuilder: (context) => [
          PopupMenuItem(value: 'edit', child: Text(t('Edit', 'Изменить'))),
          PopupMenuItem(
              value: 'enabled',
              child: Text(enabled
                  ? t('Block', 'Заблокировать')
                  : t('Unblock', 'Разблокировать'))),
          PopupMenuItem(
              value: 'revoke',
              child: Text(t('Revoke sessions', 'Отозвать сеансы'))),
          if (row['role'] != 'user')
            PopupMenuItem(
                value: 'reset',
                child: Text(t('Request MFA reset', 'Запросить сброс MFA'))),
        ],
        onSelected: (action) {
          switch (action) {
            case 'edit':
              _edit(row);
            case 'enabled':
              _save(path, 'PUT', body: {'enabled': !enabled});
            case 'revoke':
              _save('$path/revoke-sessions', 'POST');
            case 'reset':
              _reset(path);
          }
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: corporateSession,
        builder: (context, _) => AlertDialog(
          title: Text(
              t('Administration → Users', 'Администрирование → Пользователи')),
          content: SizedBox(
            width: 620,
            height: 425,
            child: !corporateSession.isAdmin
                ? Text(t('Administrator required.',
                    'Требуются права администратора.'))
                : Column(children: [
                    TextField(
                        controller: _search,
                        maxLength: 100,
                        onSubmitted: (_) => setState(() {
                              _offset = 0;
                              _fetch();
                            }),
                        decoration: InputDecoration(
                            labelText: t('Login or name', 'Логин или имя'),
                            suffixIcon: IconButton(
                                icon: const Icon(Icons.search),
                                onPressed: () => setState(() {
                                      _offset = 0;
                                      _fetch();
                                    })))),
                    if (_notice != null) Text(_notice!),
                    Expanded(
                        child: FutureBuilder<dynamic>(
                      future: _rows,
                      builder: (context, snapshot) {
                        if (snapshot.hasError)
                          return Text(_error(snapshot.error!));
                        if (!snapshot.hasData)
                          return const Center(
                              child: CircularProgressIndicator());
                        final rows = snapshot.data as List;
                        return Column(children: [
                          Expanded(
                              child: rows.isEmpty
                                  ? Text(t('No users found.',
                                      'Пользователи не найдены.'))
                                  : ListView.builder(
                                      itemCount: rows.length,
                                      itemBuilder: (context, i) => _row(
                                          rows[i] as Map<String, dynamic>))),
                          if (_offset > 0 || rows.length == 100)
                            Wrap(children: [
                              TextButton(
                                  onPressed: _offset == 0
                                      ? null
                                      : () => setState(() {
                                            _offset -= 100;
                                            _fetch();
                                          }),
                                  child: Text(t('Previous', 'Назад'))),
                              TextButton(
                                  onPressed: rows.length != 100
                                      ? null
                                      : () => setState(() {
                                            _offset += 100;
                                            _fetch();
                                          }),
                                  child: Text(t('Next', 'Далее'))),
                            ]),
                        ]);
                      },
                    )),
                  ]),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(t('Close', 'Закрыть'))),
            if (corporateSession.isAdmin)
              FilledButton(
                  onPressed: _busy ? null : () => _edit(),
                  child: Text(t('Create user', 'Создать пользователя'))),
          ],
        ),
      );
}
