import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/utils/multi_window_manager.dart';

import '../rdp/rdp_launcher.dart';
import '../rdp/rdp_profile_store.dart';
import '../rdp/rdp_workspace.dart';
import '../ssh/models/ssh_profile.dart';
import '../ssh/pages/ssh_workspace.dart';
import '../ssh/storage/ssh_repository.dart';
import 'catalog_codec.dart';
import 'connection_launcher.dart';
import 'connection_profile.dart';
import 'connection_repository.dart';
import 'connections_workspace.dart';

/// Wires the catalog to the existing desktop workspaces and native bridge.
class DesktopConnections {
  DesktopConnections({required this.showSsh});

  final VoidCallback showSsh;
  final _ssh = GlobalKey<SshWorkspaceState>();
  final _rdp = GlobalKey<RdpWorkspaceState>();
  final _catalog = GlobalKey<ConnectionsWorkspaceState>();
  final _changes = ValueNotifier<int>(0);
  final _sshRepository = SshRepository();
  final _rdpStore = RdpProfileStore();
  final _rdpLauncher = RdpLauncher();
  Set<String> _remoteIds = {};
  bool _disposed = false;
  bool _readingWindows = false;
  bool _observingPeers = false;
  late final _repository = ConnectionRepository(
    ssh: _sshRepository,
    rdp: _rdpStore,
    nativePeers: _loadPeers,
  );
  late final _launcher = ConnectionLauncher(
    rdp: _rdpLauncher,
    openRemoteDesktop: _openRemote,
    openSshTab: _openSsh,
  );

  Widget catalog(String language,
      {required bool visible,
      bool unified = false,
      bool allowProfessional = true,
      bool managementAvailable = false}) {
    if (unified && !_observingPeers) {
      _observingPeers = true;
      gFFI.lanPeersModel.addListener(_refreshCatalog);
      unawaited(bind.mainLoadLanPeers());
    }
    return ConnectionsWorkspace(
      key: _catalog,
      language: language,
      visible: visible,
      repository: _repository,
      launcher: _launcher,
      activity: _activity,
      sessionChanges: _changes,
      refreshActivity: _readRemoteTabs,
      unified: unified,
      allowProfessional: allowProfessional,
      managementAvailable: managementAvailable,
    );
  }

  void _refreshCatalog() {
    if (!_disposed) unawaited(_catalog.currentState?.reload());
  }

  Widget ssh(String language) => SshWorkspace(
        key: _ssh,
        language: language,
        repository: _sshRepository,
        onConnected: (id) => _record(_repository.markSshConnected(id)),
        onSessionChanged: _notify,
      );

  Widget rdp(String language) => RdpWorkspace(
        key: _rdp,
        language: language,
        store: _rdpStore,
        launcher: _rdpLauncher,
        onLaunched: (id) => _record(_repository.markRdpLaunched(id)),
      );

  void refreshSsh() => _ssh.currentState?.refreshProfiles();

  void refreshRdp() => _rdp.currentState?.refreshProfiles();

  void dispose() {
    _disposed = true;
    if (_observingPeers) gFFI.lanPeersModel.removeListener(_refreshCatalog);
    _changes.dispose();
  }

  void _notify() {
    if (_disposed) return;
    _changes.value++;
  }

  Future<void> _record(Future<void> operation) async {
    try {
      await operation;
      if (!_disposed) await _catalog.currentState?.reload();
    } catch (_) {
      if (!_disposed) _catalog.currentState?.historyUnavailable();
    }
  }

  Future<void> _openRemote(String id, bool relay) async {
    final context = _catalog.currentContext;
    if (context == null || _disposed || bind.isIncomingOnly()) {
      throw UnsupportedError('Outgoing remote desktop is unavailable');
    }
    await connect(context, id, forceRelay: relay);
    await _readRemoteTabs();
  }

  Future<void> _openSsh(SshProfile profile, bool filesOnly) async {
    showSsh();
    await WidgetsBinding.instance.endOfFrame;
    final workspace = _ssh.currentState;
    if (workspace == null || _disposed) {
      throw StateError('SSH workspace unavailable');
    }
    workspace.openProfile(profile, filesOnly: filesOnly);
  }

  ConnectionActivity _activity(ConnectionProfile profile) =>
      switch (profile.options) {
        SshConnectionOptions(:final transport) => (_ssh.currentState
                        ?.activeCount(transport.id,
                            filesOnly: transport.filesOnly) ??
                    0) >
                0
            ? ConnectionActivity.connected
            : _ssh.currentState?.isConnecting(transport.id,
                        filesOnly: transport.filesOnly) ==
                    true
                ? ConnectionActivity.connecting
                : ConnectionActivity.none,
        RdpOptions(:final transport) =>
          _rdpLauncher.runningClients(transport.id) > 0
              ? ConnectionActivity.rdpClient
              : ConnectionActivity.none,
        RemoteDesktopOptions() => _remoteIds
                .contains(RemoteDesktopOptions.comparableTarget(profile.host))
            ? ConnectionActivity.remoteTab
            : ConnectionActivity.none,
      };

  Future<void> _readRemoteTabs() async {
    if (_readingWindows || _disposed) return;
    _readingWindows = true;
    try {
      _remoteIds = (await rustDeskWinManager.openRemoteDesktopIds())
          .map(RemoteDesktopOptions.comparableTarget)
          .toSet();
    } finally {
      _readingWindows = false;
    }
  }

  static Future<List<NativePeer>> _loadPeers() async {
    final favorites = (await bind.mainGetFav()).toSet();
    final peers = await bind.mainLoadRecentPeersForAb(filter: '[]');
    final byId = <String, NativePeer>{};
    if (peers.isNotEmpty) {
      for (final entry in (jsonDecode(peers) as List).cast<Json>()) {
        final id = entry['id'] as String;
        if (id.isEmpty) continue;
        final millis = int.tryParse(entry['recent_millis'] as String? ?? '');
        final alias = entry['alias'] as String? ?? '';
        final hostname = entry['hostname'] as String? ?? '';
        byId[id] = (
          id: id,
          name: alias.isNotEmpty
              ? alias
              : hostname.isNotEmpty
                  ? hostname
                  : id.split('?').first,
          username: entry['username'] as String? ?? '',
          favorite: favorites.contains(id),
          recentAt: millis == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true),
        );
      }
    }
    for (final peer in [
      ...gFFI.abModel.allPeers(),
      ...gFFI.lanPeersModel.peers
    ]) {
      if (peer.id.isEmpty) continue;
      byId.putIfAbsent(
          peer.id,
          () => (
                id: peer.id,
                name: peer.alias.isNotEmpty
                    ? peer.alias
                    : peer.hostname.isNotEmpty
                        ? peer.hostname
                        : peer.id,
                username: peer.username,
                favorite: favorites.contains(peer.id),
                recentAt: null,
              ));
    }
    for (final id in favorites.where((id) => id.isNotEmpty)) {
      byId.putIfAbsent(
          id,
          () => (
                id: id,
                name: id.split('?').first,
                username: '',
                favorite: true,
                recentAt: null,
              ));
    }
    return byId.values.toList();
  }
}
