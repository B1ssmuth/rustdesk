import 'dart:io';

import 'package:uuid/uuid.dart';

class RdpEndpoint {
  const RdpEndpoint._(this.host, this.port, this.ipv6);

  final String host;
  final int port;
  final bool ipv6;

  String get address => '${ipv6 ? '[$host]' : host}:$port';

  static RdpEndpoint? parse(String host, int? port) {
    host = host.trim();
    if (port == null || port < 1 || port > 65535) return null;
    final bracketed = host.startsWith('[') && host.endsWith(']');
    if (bracketed) host = host.substring(1, host.length - 1);
    if (host.contains('%')) return null;
    final ip = InternetAddress.tryParse(host);
    if (ip?.type == InternetAddressType.IPv6) {
      return RdpEndpoint._(ip!.address, port, true);
    }
    if (bracketed || !isDnsName(host)) return null;
    if (RegExp(r'^[\d.]+$').hasMatch(host) &&
        ip?.type != InternetAddressType.IPv4) {
      return null;
    }
    return RdpEndpoint._(host.toLowerCase(), port, false);
  }

  static bool isDnsName(String host) {
    if (host.isEmpty || host.length > 253) return false;
    final name = host.endsWith('.') ? host.substring(0, host.length - 1) : host;
    final label = RegExp(r'^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$');
    return name.split('.').every(label.hasMatch);
  }
}

class RdpProfile {
  RdpProfile({
    String? id,
    required String name,
    required this.endpoint,
    String username = '',
    this.width = 1600,
    this.height = 900,
    this.scaleToWindow = true,
    this.fullscreen = false,
    this.clipboard = false,
    String gateway = '',
  })  : id = id ?? const Uuid().v4(),
        name = name.trim(),
        username = username.trim(),
        gateway = gateway.trim().toLowerCase() {
    if (!validText(name, 100) || this.name.isEmpty) {
      throw const FormatException('Invalid RDP profile name');
    }
    if (!validText(username, 256)) {
      throw const FormatException('Invalid Windows username');
    }
    if (!validDimension(width) || !validDimension(height)) {
      throw const FormatException('Invalid RDP resolution');
    }
    if (!validGateway(gateway)) {
      throw const FormatException('Invalid RD Gateway name');
    }
  }

  final String id;
  final String name;
  final RdpEndpoint endpoint;
  final String username;
  final int width;
  final int height;
  final bool scaleToWindow;
  final bool fullscreen;
  final bool clipboard;
  final String gateway;

  static bool validText(String text, int maxLength) =>
      text.length <= maxLength &&
      !text.codeUnits.any((unit) =>
          unit < 32 ||
          (unit >= 127 && unit <= 159) ||
          unit == 0x2028 ||
          unit == 0x2029);

  static bool validDimension(int? value) =>
      value != null && value >= 200 && value <= 8192;

  static bool validGateway(String value) {
    final host = value.trim();
    return host.isEmpty ||
        (RdpEndpoint.isDnsName(host) && !RegExp(r'^[\d.]+$').hasMatch(host));
  }

  factory RdpProfile.fromJson(Map<String, dynamic> json) {
    final endpoint =
        RdpEndpoint.parse(json['host'] as String, json['port'] as int);
    if (endpoint == null) throw const FormatException('Invalid RDP endpoint');
    return RdpProfile(
      id: json['id'] as String,
      name: json['name'] as String,
      endpoint: endpoint,
      username: json['username'] as String,
      width: json['width'] as int,
      height: json['height'] as int,
      scaleToWindow: json['scaleToWindow'] as bool,
      fullscreen: json['fullscreen'] as bool,
      clipboard: json['clipboard'] as bool,
      gateway: json['gateway'] as String,
    );
  }

  Map<String, Object> toJson() => {
        'id': id,
        'name': name,
        'host': endpoint.host,
        'port': endpoint.port,
        'username': username,
        'width': width,
        'height': height,
        'scaleToWindow': scaleToWindow,
        'fullscreen': fullscreen,
        'clipboard': clipboard,
        'gateway': gateway,
      };
}

/// Only allowlisted settings are written. Authentication and gateway settings
/// cannot be relaxed through imported profile data.
String rdpConnectionFile(RdpProfile profile) {
  return [
    'full address:s:${profile.endpoint.address}',
    if (profile.username.isNotEmpty) 'username:s:${profile.username}',
    'authentication level:i:1',
    'enablecredsspsupport:i:1',
    'autoreconnection enabled:i:1',
    'screen mode id:i:${profile.fullscreen ? 2 : 1}',
    'desktopwidth:i:${profile.width}',
    'desktopheight:i:${profile.height}',
    'smart sizing:i:${profile.scaleToWindow ? 1 : 0}',
    'redirectclipboard:i:${profile.clipboard ? 1 : 0}',
    'drivestoredirect:s:',
    'redirectprinters:i:0',
    'redirectcomports:i:0',
    'redirectsmartcards:i:0',
    if (profile.gateway.isEmpty)
      'gatewayusagemethod:i:0'
    else ...[
      'gatewayhostname:s:${profile.gateway}',
      'gatewayusagemethod:i:1',
      'gatewayprofileusagemethod:i:1',
      'promptcredentialonce:i:0',
    ],
    '',
  ].join('\r\n');
}
