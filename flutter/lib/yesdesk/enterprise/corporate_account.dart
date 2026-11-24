import 'package:flutter/material.dart';

import 'corporate_session.dart';

class CorporateAccount extends StatefulWidget {
  const CorporateAccount({super.key});

  @override
  State<CorporateAccount> createState() => _CorporateAccountState();
}

class _CorporateAccountState extends State<CorporateAccount> {
  bool _failed = false;

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
              OutlinedButton(
                onPressed:
                    corporateSession.configured && !corporateSession.signingIn
                        ? () async {
                            setState(() => _failed = false);
                            try {
                              await corporateSession.signIn();
                            } catch (_) {
                              if (mounted) setState(() => _failed = true);
                            }
                          }
                        : null,
                child: Text(t('Sign in with corporate account',
                    'Войти через корпоративную учётную запись')),
              ),
              if (corporateSession.signingIn)
                Text(t('Complete sign-in in your browser.',
                    'Завершите вход в браузере.')),
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
                    onPressed: corporateSession.signOut,
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
  bool _devices = false;
  Map<String, dynamic>? _employee;
  String? _notice;

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

  Future<dynamic> _searchDirectory() =>
      corporateSession.api(_devices ? '/v1/devices' : '/v1/employees',
          query: {'q': _search.text.trim()});

  void _reload() => setState(() {
        _employee = null;
        _notice = null;
        _result = _searchDirectory();
      });

  Future<void> _connect(String id) async {
    try {
      await corporateSession.api('/v1/devices/$id/connection', post: true);
    } on CorporateApiError catch (error) {
      if (!mounted) return;
      setState(() => _notice = error.statusCode == 501
          ? t('Endpoint authorization is pending.',
              'Авторизация на компьютере ещё не настроена.')
          : t('Connection denied or device unavailable.',
              'Доступ запрещён или компьютер недоступен.'));
    } catch (_) {
      if (mounted) {
        setState(() => _notice =
            t('Management API unavailable.', 'Management API недоступен.'));
      }
    }
  }

  ListTile _device(Map<String, dynamic> row, {required bool latest}) {
    final heartbeat = DateTime.tryParse('${row['last_heartbeat']}')?.toLocal();
    final online = heartbeat != null &&
        DateTime.now().difference(heartbeat) < const Duration(minutes: 2);
    final hardware = row['metadata'] as Map<String, dynamic>? ?? {};
    final detail = [
      '${row['dns_name']} · ID ${row['yesdesk_id']}',
      online ? t('Available', 'Доступен') : t('Data stale', 'Данные устарели'),
      if (heartbeat != null) '${t('Heartbeat', 'Последняя связь')} $heartbeat',
      if (row['is_primary'] == true)
        t('Primary workplace', 'Основное рабочее место'),
      if (latest)
        t('Last confirmed workplace', 'Последнее подтверждённое рабочее место'),
      if (row['active_confirmed'] == true)
        t('Active session confirmed', 'Активный сеанс подтверждён'),
      if (row['last_logon'] != null)
        '${t('Last logon', 'Последний вход')} ${row['last_logon']}',
      if (row['last_active'] != null)
        '${t('Last active', 'Последняя активность')} ${row['last_active']}',
      if (row['last_logoff'] != null)
        '${t('Last logoff', 'Последний выход')} ${row['last_logoff']}',
      for (final key in ['os', 'model', 'cpu'])
        if (hardware[key] != null && hardware[key] != '') '${hardware[key]}',
      if (hardware['ram_bytes'] case final int bytes)
        'RAM ${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GiB',
      if (hardware['disks'] case final List disks)
        for (final disk in disks)
          '${disk['name']} ${(disk['bytes'] / (1024 * 1024 * 1024)).toStringAsFixed(1)} GiB',
    ];
    return ListTile(
      title: Text('${row['hostname']}'),
      subtitle: Text(detail.join('\n')),
      trailing: row['can_request_consent'] == true && online
          ? TextButton(
              onPressed: () => _connect(row['id'] as String),
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
                    if (_employee == null) ...[
                      Wrap(
                        children: [
                          TextButton(
                            onPressed: () {
                              _devices = false;
                              _reload();
                            },
                            child: Text(t('Employees', 'Сотрудники')),
                          ),
                          TextButton(
                            onPressed: () {
                              _devices = true;
                              _reload();
                            },
                            child: Text(t('Computers', 'Компьютеры')),
                          ),
                        ],
                      ),
                      TextField(
                        controller: _search,
                        maxLength: 100,
                        onSubmitted: (_) => _reload(),
                        decoration: InputDecoration(
                          labelText: t('Search', 'Поиск'),
                          suffixIcon: IconButton(
                            onPressed: _reload,
                            icon: const Icon(Icons.search),
                          ),
                        ),
                      ),
                    ] else ...[
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          onPressed: _reload,
                          child: Text(
                              t('Back to employees', 'К списку сотрудников')),
                        ),
                      ),
                      ListTile(
                        title: Text('${_employee!['display_name']}'),
                        subtitle: Text('${_employee!['department']}\n'
                            '${_employee!['username']} · ${_employee!['sid']}'),
                      ),
                    ],
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
                          final workplace = _employee != null;
                          final rows = (workplace
                              ? snapshot.data['devices']
                              : snapshot.data) as List;
                          if (rows.isEmpty) {
                            return Text(t('No results.', 'Нет результатов.'));
                          }
                          return ListView.builder(
                            itemCount: rows.length,
                            itemBuilder: (context, index) {
                              final row = rows[index] as Map<String, dynamic>;
                              if (_devices || workplace) {
                                return _device(row,
                                    latest: workplace &&
                                        row['id'] ==
                                            snapshot.data['last_workplace_id']);
                              }
                              return ListTile(
                                title: Text('${row['display_name']}'),
                                subtitle: Text('${row['department']}'),
                                onTap: () => setState(() {
                                  _employee = row;
                                  final sid =
                                      Uri.encodeComponent(row['sid'] as String);
                                  _result = corporateSession
                                      .api('/v1/employees/$sid/workplaces');
                                }),
                              );
                            },
                          );
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
