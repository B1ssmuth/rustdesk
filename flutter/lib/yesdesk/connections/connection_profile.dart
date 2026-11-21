import '../rdp/rdp_profile.dart';
import '../ssh/models/ssh_profile.dart';

enum ConnectionType { remoteDesktop, ssh, sftp, rdp }

sealed class TransportOptions {
  const TransportOptions();

  ConnectionType get type;
}

final class RemoteDesktopOptions extends TransportOptions {
  const RemoteDesktopOptions({this.forceRelay = false});

  final bool forceRelay;

  @override
  ConnectionType get type => ConnectionType.remoteDesktop;

  // Accept the ordinary ID, direct-address and ID@server forms. URL query
  // parameters belong to RustDesk's native connection flow.
  static bool validTarget(String value) =>
      value.isNotEmpty &&
      value.length <= 512 &&
      RegExp(r'^[a-zA-Z0-9_.:\[\]%-]+(?:@[a-zA-Z0-9_.:\[\]%-]+)?(?:/r)?$')
          .hasMatch(value);
}

sealed class SshConnectionOptions extends TransportOptions {
  const SshConnectionOptions(this.transport);

  final SshProfile transport;
}

final class TerminalOptions extends SshConnectionOptions {
  const TerminalOptions(super.transport);

  @override
  ConnectionType get type => ConnectionType.ssh;
}

final class SftpOptions extends SshConnectionOptions {
  const SftpOptions(super.transport);

  @override
  ConnectionType get type => ConnectionType.sftp;
}

final class RdpOptions extends TransportOptions {
  const RdpOptions(this.transport);

  final RdpProfile transport;

  @override
  ConnectionType get type => ConnectionType.rdp;
}

class ConnectionFolder {
  const ConnectionFolder(this.id, this.name, this.parentId);

  final String id;
  final String name;
  final String? parentId;
}

class ConnectionProfile {
  ConnectionProfile({
    required this.id,
    required this.name,
    required this.host,
    required this.options,
    this.port,
    this.username = '',
    this.folderId,
    Iterable<String> tags = const [],
    this.favorite = false,
    this.pinned = false,
    this.createdAt,
    this.updatedAt,
    this.lastConnectedAt,
    this.nativePeer = false,
  }) : tags = Set.unmodifiable(tags);

  final String id;
  final String name;
  final String host;
  final int? port;
  final String username;
  final String? folderId;
  final Set<String> tags;
  final bool favorite;
  final bool pinned;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final DateTime? lastConnectedAt;
  final bool nativePeer;
  final TransportOptions options;

  ConnectionType get type => options.type;
  String? get secretRef => switch (options) {
        SshConnectionOptions(:final transport) => transport.secretRef,
        _ => null,
      };

  String get address {
    final target =
        port == null ? host : '${host.contains(':') ? '[$host]' : host}:$port';
    return username.isEmpty ? target : '$username@$target';
  }

  ConnectionProfile copyWith({
    bool? favorite,
    bool? pinned,
    DateTime? lastConnectedAt,
  }) =>
      ConnectionProfile(
        id: id,
        name: name,
        host: host,
        port: port,
        username: username,
        options: options,
        folderId: folderId,
        tags: tags,
        favorite: favorite ?? this.favorite,
        pinned: pinned ?? this.pinned,
        createdAt: createdAt,
        updatedAt: updatedAt,
        lastConnectedAt: lastConnectedAt ?? this.lastConnectedAt,
        nativePeer: nativePeer,
      );
}

/// Corporate identities and permissions belong to the management server.
class CorporateDevice {
  const CorporateDevice({
    required this.serverId,
    required this.displayName,
    required this.allowedTransports,
  });

  final String serverId;
  final String displayName;
  final Set<ConnectionType> allowedTransports;
}

abstract interface class CorporateDevicesProvider {
  Future<List<CorporateDevice>> listDevices();
}
