class SshStrings {
  SshStrings(String language)
      : russian = language.toLowerCase().split(RegExp('[-_]')).first == 'ru';

  final bool russian;

  String text(String english, String russian) =>
      this.russian ? russian : english;
  String get title => text('SSH Terminal', 'SSH-терминал');
  String get cancel => text('Cancel', 'Отмена');
  String get close => text('Close', 'Закрыть');
  String get connect => text('Connect', 'Подключить');
  String get save => text('Save', 'Сохранить');
  String get delete => text('Delete', 'Удалить');
  String get password => text('Password', 'Пароль');
  String get privateKey => text('Private key', 'Приватный ключ');
  String get passphrase => text('Passphrase', 'Пароль ключа');
  String get dark => text('Dark', 'Тёмная');
  String get light => text('Light', 'Светлая');
  String get group => text('Group', 'Группа');
  String get name => text('Name', 'Название');
  String get host => text('Host or IP address', 'Хост или IP-адрес');
  String get edit => text('Edit', 'Изменить');
  String get favorite => text('Favorite', 'Избранное');
  String get search => text('Search', 'Поиск');
  String get keyboardInteractive =>
      text('Keyboard-interactive', 'Интерактивная аутентификация');
}
