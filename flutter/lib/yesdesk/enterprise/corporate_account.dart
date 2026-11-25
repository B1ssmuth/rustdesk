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
                ],
              ),
            ],
          ],
        );
      },
    );
  }
}

class WorkspaceAccount extends StatelessWidget {
  const WorkspaceAccount({super.key, required this.ru});
  final bool ru;

  @override
  Widget build(BuildContext context) {
    String t(String en, String russian) => ru ? russian : en;
    void open() => showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(t('Corporate account', 'Корпоративная учётная запись')),
            scrollable: true,
            content: const SizedBox(width: 375, child: CorporateAccount()),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(t('Close', 'Закрыть'))),
            ],
          ),
        );
    return ListenableBuilder(
        listenable: corporateSession,
        builder: (context, _) {
          final profile = corporateSession.profile;
          if (profile == null) {
            return OutlinedButton.icon(
                onPressed: open,
                icon: const Icon(Icons.login),
                label: Text(t('Sign in', 'Войти')));
          }
          final role = switch (profile['role']) {
            'admin' => t('Administrator', 'Администратор'),
            'support' => t('Support', 'Поддержка'),
            _ => t('Employee', 'Сотрудник'),
          };
          return PopupMenuButton<String>(
            tooltip: t('Account menu', 'Меню аккаунта'),
            onSelected: (action) {
              if (action == 'users') {
                showDialog<void>(
                    context: context, builder: (_) => AdminUsers(ru: ru));
              } else {
                open();
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                  value: 'account',
                  child: Text(t('Account settings', 'Настройки аккаунта'))),
              if (corporateSession.isAdmin)
                PopupMenuItem(
                    value: 'users',
                    child: Text(t('Administration → Users',
                        'Администрирование → Пользователи'))),
            ],
            child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 210),
                child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text('${profile['display_name']} · $role',
                        maxLines: 1, overflow: TextOverflow.ellipsis))),
          );
        });
  }
}
