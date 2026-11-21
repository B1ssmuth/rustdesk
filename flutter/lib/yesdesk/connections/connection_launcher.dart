import 'dart:io';

import '../rdp/rdp_launcher.dart';
import '../ssh/models/ssh_profile.dart';
import 'connection_profile.dart';

typedef OpenRemoteDesktop = Future<void> Function(String id, bool forceRelay);
typedef OpenSshTab = Future<void> Function(SshProfile profile, bool filesOnly);

class ConnectionLauncher {
  ConnectionLauncher({
    required this.openRemoteDesktop,
    required this.openSshTab,
    required this.rdp,
  });

  final OpenRemoteDesktop openRemoteDesktop;
  final OpenSshTab openSshTab;
  final RdpLauncher rdp;

  Future<({Future<int>? clientExit})> launch(ConnectionProfile profile) async {
    if (!Platform.isWindows && !Platform.isLinux && !Platform.isMacOS) {
      throw UnsupportedError('Desktop connections require a desktop OS');
    }
    switch (profile.options) {
      case RemoteDesktopOptions(:final forceRelay):
        if (!RemoteDesktopOptions.validTarget(profile.host)) {
          throw const FormatException('Invalid remote desktop target');
        }
        await openRemoteDesktop(profile.host, forceRelay);
        return (clientExit: null);
      case SshConnectionOptions(:final transport):
        await openSshTab(transport, profile.type == ConnectionType.sftp);
        return (clientExit: null);
      case RdpOptions(:final transport):
        final client = await rdp.launch(transport);
        return (clientExit: client.exitCode);
    }
  }
}
