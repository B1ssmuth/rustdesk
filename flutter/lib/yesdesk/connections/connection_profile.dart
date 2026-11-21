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

  static String visibleTarget(String value) => value.split('?').first;

  static String _withoutRelay(String value) =>
      value.endsWith('/r') || value.endsWith(r'\r')
          ? value.substring(0, value.length - 2)
          : value;

  static String comparableTarget(String value) =>
      _withoutRelay(visibleTarget(_withoutRelay(value)))
          .split('@')
          .map(_withoutRelay)
          .join('@');

  static bool validTarget(String value) {
    if (value.isEmpty ||
        value.length > 512 ||
        value.contains('?') ||
        value.contains(RegExp(r'\s'))) {
      return false;
    }
    final parts = comparableTarget(value).split('@');
    return parts.length <= 2 && parts.every(_validIdOrAddress);
  }

  static bool validNativeTarget(String value) {
    if (validTarget(value)) return true;
    final parts = _withoutRelay(value).split('?');
    return parts.length == 2 &&
        parts.first.contains('@') &&
        validTarget(parts.first) &&
        RegExp(r'^key=[a-zA-Z0-9+/=_%-]{1,256}$', caseSensitive: false)
            .hasMatch(parts.last);
  }

  static bool _validIdOrAddress(String value) {
    if (RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_-]*$').hasMatch(value) ||
        SshProfile.validHost(value)) {
      return true;
    }
    final address = RegExp(r'^(\[[^\]]+\]|[^:]+):([0-9]+)$').firstMatch(value);
    final port = int.tryParse(address?.group(2) ?? '');
    return address != null &&
        port != null &&
        port >= 1 &&
        port <= 65535 &&
        SshProfile.validHost(address.group(1)!);
  }
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

  String get displayHost => type == ConnectionType.remoteDesktop
      ? RemoteDesktopOptions.visibleTarget(host)
      : host;

  String get address {
    final target = port == null
        ? displayHost
        : '${host.contains(':') ? '[$host]' : host}:$port';
    if (username.isEmpty || type == ConnectionType.remoteDesktop) return target;
    return '$username@$target';
  }
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
