import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/peer_model.dart';
import 'package:flutter_hbb/models/state_model.dart';
import 'package:flutter_hbb/yesdesk/theme.dart';
import 'package:flutter_hbb/yesdesk/widgets.dart';
import 'package:get/get.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:window_manager/window_manager.dart';

import '../../common.dart';
import '../../common/formatter/id_formatter.dart';
import '../../common/widgets/autocomplete.dart';
import '../../common/widgets/peer_tab_page.dart';
import '../../models/platform_model.dart';

class OnlineStatusWidget extends StatefulWidget {
  const OnlineStatusWidget({super.key});

  @override
  State<OnlineStatusWidget> createState() => _OnlineStatusWidgetState();
}

class _OnlineStatusWidgetState extends State<OnlineStatusWidget> {
  final _svcStopped = Get.find<RxBool>(tag: 'stop-service');
  final _usingPublicServer = false.obs;
  Timer? _updateTimer;
  bool _updating = false;

  @override
  void initState() {
    super.initState();
    _updateTimer = periodic_immediate(const Duration(seconds: 1), _pollStatus);
  }

  @override
  void dispose() {
    _updateTimer?.cancel();
    super.dispose();
  }

  Future<void> _pollStatus() async {
    if (_updating) return;
    _updating = true;
    try {
      final status =
          jsonDecode(await bind.mainGetConnectStatus()) as Map<String, dynamic>;
      if (!mounted) return;
      stateGlobal.svcStatus.value = switch (status['status_num']) {
        0 => SvcStatus.connecting,
        1 => SvcStatus.ready,
        _ => SvcStatus.notReady,
      };
      final count = status['video_conn_count'];
      if (count is int) stateGlobal.videoConnCount.value = count;

      if (!bind.isIncomingOnly()) {
        final usingPublicServer = await bind.mainIsUsingPublicServer();
        if (mounted) _usingPublicServer.value = usingPublicServer;
      }
    } catch (_) {
      if (mounted) {
        stateGlobal.svcStatus.value = SvcStatus.notReady;
        _usingPublicServer.value = false;
      }
    } finally {
      _updating = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = YesDeskColors.of(context);
    return Obx(() {
      final stopped = _svcStopped.value;
      final status = stateGlobal.svcStatus.value;
      final publicServer = _usingPublicServer.value;
      final (label, color) = stopped
          ? ('Service is not running', colors.warning)
          : switch (status) {
              SvcStatus.ready => ('Ready', colors.accent),
              SvcStatus.connecting => (
                  'yesdesk_connecting_status',
                  colors.warning
                ),
              SvcStatus.notReady => ('not_ready_status', colors.error),
            };

      return Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: YesDeskSpace.md,
          vertical: YesDeskSpace.xs,
        ),
        child: Wrap(
          spacing: YesDeskSpace.sm,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.circle, size: 8, color: color),
                const SizedBox(width: YesDeskSpace.sm),
                Flexible(
                  child: Semantics(
                    liveRegion: true,
                    child: Text(
                      translate(label),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ),
              ],
            ),
            if (stopped)
              TextButton(
                onPressed: () => start_service(true),
                child: Text(translate('Start service')),
              ),
            if (!stopped && status == SvcStatus.ready && publicServer)
              TextButton(
                onPressed: () =>
                    launchUrlString('https://rustdesk.com/pricing'),
                child: Text(translate('setup_server_tip')),
              ),
          ],
        ),
      );
    });
  }
}

enum _ConnectionAction { transfer, camera, terminal }

class ConnectionPage extends StatefulWidget {
  const ConnectionPage({super.key});

  @override
  State<ConnectionPage> createState() => _ConnectionPageState();
}

class _ConnectionPageState extends State<ConnectionPage> with WindowListener {
  final _idController = IDTextEditingController();
  final _idFocusNode = FocusNode();
  final _allPeersLoader = AllPeersLoader();
  bool _isWindowMinimized = false;

  @override
  void initState() {
    super.initState();
    _allPeersLoader.init((update) {
      if (mounted) setState(update);
    });
    _idFocusNode.addListener(_onFocusChanged);
    Get.put<IDTextEditingController>(_idController);
    windowManager.addListener(this);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final lastRemoteId = await bind.mainGetLastRemoteId();
      if (mounted && !_idFocusNode.hasFocus && _idController.text.isEmpty) {
        _idController.id = lastRemoteId;
      }
    });
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    _allPeersLoader.clear();
    _idFocusNode.dispose();
    Get.delete<IDTextEditingController>();
    _idController.dispose();
    super.dispose();
  }

  @override
  void onWindowEvent(String eventName) {
    super.onWindowEvent(eventName);
    if (eventName == 'minimize') {
      _isWindowMinimized = true;
    } else if (eventName == 'maximize' || eventName == 'restore') {
      if (_isWindowMinimized && isWindows) {
        // windows can't update when minimized.
        Get.forceAppUpdate();
      }
      _isWindowMinimized = false;
    }
  }

  @override
  void onWindowEnterFullScreen() {
    // Remove edge border by setting the value to zero.
    stateGlobal.resizeEdgeSize.value = 0;
  }

  @override
  void onWindowLeaveFullScreen() {
    // Restore edge border to default edge size.
    stateGlobal.resizeEdgeSize.value = stateGlobal.isMaximized.isTrue
        ? kMaximizeEdgeSize
        : windowResizeEdgeSize;
  }

  @override
  void onWindowClose() {
    super.onWindowClose();
    bind.mainOnMainWindowClose();
  }

  void _onFocusChanged() {
    if (!_idFocusNode.hasFocus) return;
    _allPeersLoader.getAllPeers();
    _idController.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _idController.text.length,
    );
  }

  void _connect([_ConnectionAction? action]) {
    connect(
      context,
      _idController.id,
      isFileTransfer: action == _ConnectionAction.transfer,
      isViewCamera: action == _ConnectionAction.camera,
      isTerminal: action == _ConnectionAction.terminal,
    );
  }

  Iterable<Peer> _matchingPeers(TextEditingValue value) {
    final id = trimID(value.text);
    if (id.isEmpty) return const [];
    final query = (int.tryParse(id) == null ? value.text : id).toLowerCase();
    return _allPeersLoader.peers.where((peer) =>
        peer.id.toLowerCase().contains(query) ||
        peer.username.toLowerCase().contains(query) ||
        peer.hostname.toLowerCase().contains(query) ||
        peer.alias.toLowerCase().contains(query));
  }

  Widget _idField() {
    return LayoutBuilder(
      builder: (context, constraints) => RawAutocomplete<Peer>(
        focusNode: _idFocusNode,
        textEditingController: _idController,
        displayStringForOption: (peer) => formatID(peer.id),
        optionsBuilder: _matchingPeers,
        fieldViewBuilder: (context, controller, focusNode, selectSuggestion) {
          return TextField(
            controller: controller,
            focusNode: focusNode,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.visiblePassword,
            textInputAction: TextInputAction.go,
            style: const TextStyle(
              fontSize: 15,
              fontFeatures: YesDeskTheme.numericFeatures,
            ),
            decoration: InputDecoration(
              labelText: translate('Enter Remote ID'),
              prefixIcon: const Icon(Icons.dialpad_rounded, size: 17),
            ),
            inputFormatters: [IDTextInputFormatter()],
            onEditingComplete: controller.clearComposing,
            // Enter uses the keyboard-highlighted peer when there is a
            // suggestion to select. The button always connects to the ID.
            onSubmitted: (value) {
              selectSuggestion();
              if (controller.text == value) _connect();
            },
          ).workaroundFreezeLinuxMint();
        },
        optionsViewBuilder: (context, select, options) {
          final peers = options.toList();
          return Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: constraints.maxWidth,
              child: Material(
                color: YesDeskColors.of(context).surface,
                borderRadius: BorderRadius.circular(YesDeskSpace.radius),
                elevation: 4,
                clipBehavior: Clip.antiAlias,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 200),
                  child: ListView.builder(
                    padding: const EdgeInsets.only(top: YesDeskSpace.xs),
                    shrinkWrap: true,
                    itemCount: peers.length,
                    itemBuilder: (context, index) {
                      final peer = peers[index];
                      final highlighted =
                          AutocompleteHighlightedOption.of(context) == index;
                      return ColoredBox(
                        color: highlighted
                            ? YesDeskColors.of(context).selected
                            : Colors.transparent,
                        child: AutocompletePeerTile(
                          onSelect: () => select(peer),
                          peer: peer,
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  void _showConnectionHelp() {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(translate('Control Remote Desktop')),
        scrollable: true,
        content: Text(translate('id_input_tip')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(translate('Close')),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final quickConnect = ValueListenableBuilder<TextEditingValue>(
      valueListenable: _idController,
      child: _idField(),
      builder: (context, value, field) {
        final canConnect = trimID(value.text).isNotEmpty;
        return YesDeskQuickConnect(
          title: translate('Quick Connect'),
          connectLabel: translate('Connect'),
          onConnect: canConnect ? _connect : null,
          field: field!,
          help: YesDeskIconButton(
            label: translate('Help'),
            icon: Icons.help_outline_rounded,
            onPressed: _showConnectionHelp,
          ),
          actions: PopupMenuButton<_ConnectionAction>(
            enabled: canConnect,
            tooltip: translate('More'),
            icon: const Icon(Icons.keyboard_arrow_down_rounded),
            onSelected: _connect,
            itemBuilder: (_) => [
              PopupMenuItem(
                value: _ConnectionAction.transfer,
                child: Text(translate('Transfer file')),
              ),
              PopupMenuItem(
                value: _ConnectionAction.camera,
                child: Text(translate('View camera')),
              ),
              PopupMenuItem(
                value: _ConnectionAction.terminal,
                child: Text(translate('Terminal (beta)')),
              ),
            ],
          ),
        );
      },
    );

    return CallbackShortcuts(
      bindings: {
        SingleActivator(LogicalKeyboardKey.keyL,
            control: !isMacOS, meta: isMacOS): _idFocusNode.requestFocus,
      },
      child: PeerTabPage(workspaceHeader: quickConnect),
    );
  }
}
