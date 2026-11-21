import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../rdp/rdp_profile.dart';
import '../ssh/models/ssh_profile.dart';
import 'catalog_view.dart';
import 'connection_profile.dart';

typedef Json = Map<String, dynamic>;

String sourceUuid(String source, String id) =>
    const Uuid().v5(Uuid.NAMESPACE_URL, 'yesdesk:connections:$source:$id');

String requireUuid(Object? value) {
  if (value is! String ||
      !RegExp(r'^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$')
          .hasMatch(value)) {
    throw const FormatException('Invalid identifier');
  }
  return value;
}

DateTime? readDate(Object? value) =>
    value == null ? null : DateTime.parse(value as String).toUtc();

TransportOptions transportOptions(
  ConnectionType type,
  String id,
  String name,
  String host,
  int? port,
  String username,
  Json settings, {
  String group = '',
  bool favorite = false,
}) {
  if (name.trim().isEmpty ||
      !RdpProfile.validText(name, 100) ||
      !RdpProfile.validText(username, 256)) {
    throw const FormatException('Invalid profile name or username');
  }
  switch (type) {
    case ConnectionType.remoteDesktop:
      if (!RemoteDesktopOptions.validTarget(host) || port != null) {
        throw const FormatException('Invalid remote desktop target');
      }
      return RemoteDesktopOptions(
          forceRelay: settings['forceRelay'] as bool? ?? false);
    case ConnectionType.ssh:
    case ConnectionType.sftp:
      final profile = SshProfile(
        id: id,
        name: name,
        host: SshProfile.normalizeHost(host),
        port: port ?? 22,
        username: username,
        auth: SshAuth.values.byName(settings['auth'] as String? ?? 'password'),
        filesOnly: type == ConnectionType.sftp,
        group: group,
        comment: settings['comment'] as String? ?? '',
        favorite: favorite,
        timeoutSeconds: settings['timeoutSeconds'] as int? ?? 15,
        fontSize: (settings['fontSize'] as num?)?.toDouble() ?? 14,
        scrollback: settings['scrollback'] as int? ?? 5000,
        palette:
            SshPalette.values.byName(settings['palette'] as String? ?? 'dark'),
      );
      return profile.filesOnly
          ? SftpOptions(profile)
          : TerminalOptions(profile);
    case ConnectionType.rdp:
      final endpoint = RdpEndpoint.parse(host, port ?? 3389);
      if (endpoint == null) throw const FormatException('Invalid RDP endpoint');
      return RdpOptions(RdpProfile(
        id: id,
        name: name,
        endpoint: endpoint,
        username: username,
        width: settings['width'] as int? ?? 1600,
        height: settings['height'] as int? ?? 900,
        scaleToWindow: settings['scaleToWindow'] as bool? ?? true,
        fullscreen: settings['fullscreen'] as bool? ?? false,
        clipboard: settings['clipboard'] as bool? ?? false,
        gateway: settings['gateway'] as String? ?? '',
      ));
  }
}

// Explicit allowlist. The legacy models' generic JSON includes credential
// references and may be extended independently of the transfer format.
Json transportSettings(TransportOptions options) => switch (options) {
      RemoteDesktopOptions(:final forceRelay) => {'forceRelay': forceRelay},
      SshConnectionOptions(:final transport) => {
          'auth': transport.auth.name,
          'timeoutSeconds': transport.timeoutSeconds,
          'fontSize': transport.fontSize,
          'scrollback': transport.scrollback,
          'palette': transport.palette.name,
        },
      RdpOptions(:final transport) => {
          'width': transport.width,
          'height': transport.height,
          'scaleToWindow': transport.scaleToWindow,
          'fullscreen': transport.fullscreen,
          'clipboard': transport.clipboard,
          'gateway': transport.gateway,
        },
    };

Json encodeFolder(ConnectionFolder folder) =>
    {'id': folder.id, 'name': folder.name, 'parentId': folder.parentId};

ConnectionFolder decodeFolder(Json json) {
  final name = (json['name'] as String).trim();
  if (name.isEmpty || !RdpProfile.validText(name, 100)) {
    throw const FormatException('Invalid folder name');
  }
  final parent = json['parentId'];
  return ConnectionFolder(requireUuid(json['id']), name,
      parent == null ? null : requireUuid(parent));
}

Json encodeProfile(ConnectionProfile profile) => {
      'id': profile.id,
      'name': profile.name,
      'type': profile.type.name,
      'host': profile.host,
      'port': profile.port,
      'username': profile.username,
      'folderId': profile.folderId,
      'tags': profile.tags.toList(),
      'favorite': profile.favorite,
      'pinned': profile.pinned,
      'createdAt': profile.createdAt?.toIso8601String(),
      'updatedAt': profile.updatedAt?.toIso8601String(),
      'lastConnectedAt': profile.lastConnectedAt?.toIso8601String(),
      'settings': transportSettings(profile.options),
    };

ConnectionProfile decodeProfile(Json json) {
  final id = requireUuid(json['id']);
  final type = ConnectionType.values.byName(json['type'] as String);
  final name = (json['name'] as String).trim();
  final host = (json['host'] as String).trim();
  final port = json['port'] as int?;
  final username = (json['username'] as String? ?? '').trim();
  final folder = json['folderId'];
  final tags = (json['tags'] as List? ?? []).cast<String>();
  if (tags.length > 100 ||
      tags.any((tag) => tag.isEmpty || !RdpProfile.validText(tag, 100))) {
    throw const FormatException('Invalid tags');
  }
  final safeSettings = <String, dynamic>{...json['settings'] as Json? ?? {}}
    ..remove('comment');
  final options =
      transportOptions(type, id, name, host, port, username, safeSettings);
  return ConnectionProfile(
    id: id,
    name: name,
    host: switch (options) {
      SshConnectionOptions(:final transport) => transport.host,
      RdpOptions(:final transport) => transport.endpoint.host,
      _ => host,
    },
    port: switch (options) {
      SshConnectionOptions(:final transport) => transport.port,
      RdpOptions(:final transport) => transport.endpoint.port,
      _ => null,
    },
    username: username,
    options: options,
    folderId: folder == null ? null : requireUuid(folder),
    tags: tags,
    favorite: json['favorite'] as bool? ?? false,
    pinned: json['pinned'] as bool? ?? false,
    createdAt: readDate(json['createdAt']),
    updatedAt: readDate(json['updatedAt']),
    lastConnectedAt: readDate(json['lastConnectedAt']),
  );
}

String exportCatalog(ConnectionCatalog catalog) =>
    const JsonEncoder.withIndent('  ').convert({
      'format': 'yesdesk-connections',
      'version': 1,
      'folders': catalog.folders.values.map(encodeFolder).toList(),
      'profiles': catalog.profiles.values
          .where((profile) =>
              profile.type != ConnectionType.remoteDesktop ||
              RemoteDesktopOptions.validTarget(profile.host))
          .map(encodeProfile)
          .toList(),
    });

ConnectionCatalog parseCatalog(String text) {
  final Json data = jsonDecode(text) as Json;
  if (data['format'] != 'yesdesk-connections' || data['version'] != 1) {
    throw const FormatException('Unsupported catalog format');
  }
  final folders =
      (data['folders'] as List).cast<Json>().map(decodeFolder).toList();
  final profiles =
      (data['profiles'] as List).cast<Json>().map(decodeProfile).toList();
  final catalog = ConnectionCatalog(profiles, folders);
  if (catalog.profiles.length != profiles.length ||
      catalog.folders.length != folders.length ||
      profiles.any((p) =>
          p.folderId != null && !catalog.folders.containsKey(p.folderId))) {
    throw const FormatException('Duplicate or missing identifier');
  }
  return catalog;
}
