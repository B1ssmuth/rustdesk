import 'dart:io';

enum SshAuth { password, privateKey, keyboardInteractive }

enum SshPalette { dark, light }

class SshProfile {
  SshProfile({
    required this.id,
    required this.name,
    required this.host,
    this.port = 22,
    required this.username,
    this.auth = SshAuth.password,
    this.group = '',
    this.comment = '',
    this.favorite = false,
    this.filesOnly = false,
    this.secretRef,
    this.timeoutSeconds = 15,
    this.fontSize = 14,
    this.scrollback = 5000,
    this.palette = SshPalette.dark,
  }) {
    if (id.isEmpty ||
        name.trim().isEmpty ||
        !validHost(host) ||
        port < 1 ||
        port > 65535 ||
        username.trim().isEmpty ||
        timeoutSeconds < 1 ||
        timeoutSeconds > 120 ||
        !fontSize.isFinite ||
        fontSize < 8 ||
        fontSize > 36 ||
        scrollback < 100 ||
        scrollback > 20000) {
      throw const FormatException('Invalid SSH profile');
    }
  }

  final String id;
  final String name;
  final String host;
  final int port;
  final String username;
  final SshAuth auth;
  final String group;
  final String comment;
  final bool favorite;
  final bool filesOnly;
  final String? secretRef;
  final int timeoutSeconds;
  final double fontSize;
  final int scrollback;
  final SshPalette palette;

  static String normalizeHost(String value) {
    var host = value.trim();
    if (host.startsWith('[') && host.endsWith(']')) {
      host = host.substring(1, host.length - 1);
    }
    final ip = InternetAddress.tryParse(host);
    if (ip != null && !host.contains('%')) {
      return InternetAddress.fromRawAddress(ip.rawAddress, type: ip.type)
          .address;
    }
    return host.contains('%') ? host : host.toLowerCase();
  }

  static bool validHost(String value) {
    final host = normalizeHost(value);
    if (InternetAddress.tryParse(host) != null) return true;
    if (host.contains('%')) {
      final parts = host.split('%');
      return parts.length == 2 &&
          InternetAddress.tryParse(parts.first)?.type ==
              InternetAddressType.IPv6 &&
          RegExp(r'^[a-zA-Z0-9_.-]+$').hasMatch(parts.last);
    }
    return host.length <= 254 &&
        RegExp(r'^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)*[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.?$')
            .hasMatch(host);
  }

  String get endpoint => '[${normalizeHost(host)}]:$port';

  factory SshProfile.fromJson(Map<String, dynamic> json) => SshProfile(
        id: json['id'] as String,
        name: json['name'] as String,
        host: json['host'] as String,
        port: json['port'] as int? ?? 22,
        username: json['username'] as String,
        auth: SshAuth.values.byName(json['auth'] as String? ?? 'password'),
        group: json['group'] as String? ?? '',
        comment: json['comment'] as String? ?? '',
        favorite: json['favorite'] as bool? ?? false,
        filesOnly: json['filesOnly'] as bool? ?? false,
        secretRef: json['secretRef'] as String?,
        timeoutSeconds: json['timeoutSeconds'] as int? ?? 15,
        fontSize: (json['fontSize'] as num?)?.toDouble() ?? 14,
        scrollback: json['scrollback'] as int? ?? 5000,
        palette: SshPalette.values.byName(json['palette'] as String? ?? 'dark'),
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'host': host,
        'port': port,
        'username': username,
        'auth': auth.name,
        'group': group,
        'comment': comment,
        'favorite': favorite,
        if (filesOnly) 'filesOnly': true,
        'secretRef': secretRef,
        'timeoutSeconds': timeoutSeconds,
        'fontSize': fontSize,
        'scrollback': scrollback,
        'palette': palette.name,
      };

  SshProfile withSecret(String? reference) =>
      SshProfile.fromJson({...toJson(), 'secretRef': reference});
}
