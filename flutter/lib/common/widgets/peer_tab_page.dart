import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/common/widgets/address_book.dart';
import 'package:flutter_hbb/common/widgets/dialog.dart';
import 'package:flutter_hbb/common/widgets/my_group.dart';
import 'package:flutter_hbb/common/widgets/peers_view.dart';
import 'package:flutter_hbb/common/widgets/peer_card.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/desktop/widgets/popup_menu.dart';
import 'package:flutter_hbb/desktop/widgets/material_mod_popup_menu.dart'
    as mod_menu;
import 'package:flutter_hbb/desktop/widgets/tabbar_widget.dart';
import 'package:flutter_hbb/models/ab_model.dart';
import 'package:flutter_hbb/models/peer_model.dart';

import 'package:flutter_hbb/models/peer_tab_model.dart';
import 'package:flutter_hbb/models/state_model.dart';
import 'package:flutter_hbb/yesdesk/connections/desktop_connections_stub.dart'
    if (dart.library.io) 'package:flutter_hbb/yesdesk/connections/desktop_connections.dart';
import 'package:flutter_hbb/yesdesk/ssh/widgets/ssh_strings.dart';
import 'package:flutter_hbb/yesdesk/theme.dart';
import 'package:flutter_hbb/yesdesk/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:get/get.dart';
import 'package:provider/provider.dart';
import 'package:pull_down_button/pull_down_button.dart';

import '../../common.dart';
import '../../models/platform_model.dart';

class PeerTabPage extends StatefulWidget {
  const PeerTabPage({super.key, this.workspaceHeader});

  final Widget? workspaceHeader;
  @override
  State<PeerTabPage> createState() => _PeerTabPageState();
}

class _TabEntry {
  final Widget widget;
  final Function({dynamic hint})? load;
  _TabEntry(this.widget, [this.load]);
}

EdgeInsets? _menuPadding() {
  return (isDesktop || isWebDesktop) ? kDesktopMenuPadding : null;
}

enum _WorkspaceSection { devices, ssh, rdp, catalog }

enum _SidebarMode { full, compact, hidden }

const _sidebarOption = 'yesdesk-sidebar-mode';

class _PeerTabPageState extends State<PeerTabPage>
    with SingleTickerProviderStateMixin {
  final List<_TabEntry> entries = [
    _TabEntry(RecentPeersView(
      menuPadding: _menuPadding(),
    )),
    _TabEntry(FavoritePeersView(
      menuPadding: _menuPadding(),
    )),
    _TabEntry(DiscoveredPeersView(
      menuPadding: _menuPadding(),
    )),
    _TabEntry(
        AddressBook(
          menuPadding: _menuPadding(),
        ),
        ({dynamic hint}) => gFFI.abModel.pullAb(
            force: hint == null ? ForcePullAb.listAndCurrent : null,
            quiet: false)),
    _TabEntry(
      MyGroup(
        menuPadding: _menuPadding(),
      ),
      ({dynamic hint}) => gFFI.groupModel.pull(force: hint == null),
    ),
  ];
  RelativeRect? mobileTabContextMenuPos;
  _SidebarMode _sidebar = _SidebarMode.full;
  _WorkspaceSection _section = _WorkspaceSection.devices;
  final Set<_WorkspaceSection> _visited = {};
  late final _connections = DesktopConnections(
    showSsh: () {
      if (mounted) _openSection(_WorkspaceSection.ssh);
    },
  );

  @override
  void dispose() {
    if (widget.workspaceHeader != null && isDesktop && !isWeb) {
      _connections.dispose();
    }
    super.dispose();
  }

  void _openSection(_WorkspaceSection section) {
    FocusManager.instance.primaryFocus?.unfocus();
    if (section == _WorkspaceSection.ssh) _connections.refreshSsh();
    if (section == _WorkspaceSection.rdp) _connections.refreshRdp();
    setState(() {
      _visited.add(section);
      _section = section;
    });
  }

  final isOptVisiableFixed = isOptionFixed(kOptionPeerTabVisible);

  @override
  void initState() {
    super.initState();
    _loadLocalOptions();
    if (widget.workspaceHeader != null) {
      final savedMode = bind.getLocalFlutterOption(k: _sidebarOption);
      _sidebar = _SidebarMode.values.firstWhere(
          (mode) => mode.name == savedMode,
          orElse: () => _SidebarMode.full);
    }
  }

  void _loadLocalOptions() {
    final option = bind.getLocalFlutterOption(k: kOptionPeerCardUiType);
    final uiType = int.tryParse(option);
    if (option.isEmpty && widget.workspaceHeader != null) {
      peerCardUiType.value = PeerUiType.list;
    } else if (uiType != null) {
      peerCardUiType.value =
          PeerUiType.values[uiType.clamp(0, PeerUiType.values.length - 1)];
    }
    hideAbTagsPanel.value =
        bind.mainGetLocalOption(key: kOptionHideAbTagsPanel) == 'Y';
  }

  Future<void> handleTabSelection(int tabIndex) async {
    if (tabIndex < entries.length) {
      if (tabIndex != gFFI.peerTabModel.currentTab) {
        gFFI.peerTabModel.setCurrentTabCachedPeers([]);
      }
      gFFI.peerTabModel.setCurrentTab(tabIndex);
      entries[tabIndex].load?.call(hint: false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final model = Provider.of<PeerTabModel>(context);
    final workspaceHeader = widget.workspaceHeader;
    if (workspaceHeader != null) {
      return _buildWorkspace(model, workspaceHeader);
    }

    Widget selectionWrap(Widget widget) {
      return model.multiSelectionMode ? createMultiSelectionBar(model) : widget;
    }

    return Column(
      textBaseline: TextBaseline.ideographic,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Obx(() => SizedBox(
              height: 32,
              child: Container(
                padding: stateGlobal.isPortrait.isTrue
                    ? EdgeInsets.symmetric(horizontal: 2)
                    : null,
                child: selectionWrap(Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                        child: visibleContextMenuListener(
                            _createSwitchBar(context))),
                    if (stateGlobal.isPortrait.isTrue)
                      ..._portraitRightActions(context)
                    else
                      ..._landscapeRightActions(context)
                  ],
                )),
              ),
            ).paddingOnly(right: stateGlobal.isPortrait.isTrue ? 0 : 12)),
        _createPeersView(),
      ],
    );
  }

  void _showSidebarOptions(PeerTabModel model, SshStrings labels) {
    showDialog<void>(
      context: context,
      builder: (context) => ListenableBuilder(
        listenable: model,
        builder: (context, _) => StatefulBuilder(
          builder: (context, updateDialog) => AlertDialog(
            title: Text(labels.text('Sidebar', 'Боковая панель')),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final (mode, label) in [
                    (_SidebarMode.full, labels.text('Full', 'Полная')),
                    (_SidebarMode.compact, labels.text('Icons', 'Значки')),
                    (_SidebarMode.hidden, labels.text('Hidden', 'Скрыта')),
                  ])
                    RadioListTile<_SidebarMode>(
                      value: mode,
                      groupValue: _sidebar,
                      title: Text(label),
                      onChanged: (value) {
                        if (!mounted || value == null) return;
                        setState(() => _sidebar = value);
                        updateDialog(() {});
                        unawaited(bind.setLocalFlutterOption(
                            k: _sidebarOption, v: value.name));
                      },
                    ),
                  const Divider(),
                  for (final tab in model.orders)
                    if (model.isEnabled[tab])
                      CheckboxListTile(
                        value: model.isVisibleEnabled[tab],
                        title: Text(model.tabTooltip(tab)),
                        onChanged:
                            isOptVisiableFixed || model.multiSelectionMode
                                ? null
                                : (value) =>
                                    model.setTabVisible(tab, value ?? false),
                      ),
                ],
              ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(labels.text('Done', 'Готово'))),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildWorkspace(PeerTabModel model, Widget header) {
    final colors = YesDeskColors.of(context);
    final tabs = model.visibleEnabledOrderedIndexs;
    final supportsSsh = isDesktop && !isWeb;
    final supportsRdp = supportsSsh && isWindows && !bind.isIncomingOnly();
    final language = supportsSsh ? bind.mainGetLocalOption(key: 'lang') : '';
    final workspaceLanguage =
        language.isEmpty ? localeName.toString() : language;
    final labels = SshStrings(workspaceLanguage);
    final tabFixed = isOptionFixed(kOptionPeerTabIndex);
    final devicesSelected = _section == _WorkspaceSection.devices;
    final sshSelected = _section == _WorkspaceSection.ssh;
    final rdpSelected = _section == _WorkspaceSection.rdp;
    final catalogSelected = _section == _WorkspaceSection.catalog;
    return LayoutBuilder(builder: (context, constraints) {
      final compact =
          _sidebar == _SidebarMode.compact || constraints.maxWidth < 690;
      final hidden = _sidebar == _SidebarMode.hidden;
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!hidden)
            SizedBox(
              width: compact ? 60 : 212,
              child: Material(
                color: colors.surface,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (supportsSsh)
                      Padding(
                        padding: const EdgeInsets.all(YesDeskSpace.sm),
                        child: YesDeskNavItem(
                          icon: Icons.folder_copy_outlined,
                          label: SshStrings(workspaceLanguage)
                              .text('My connections', 'Мои подключения'),
                          selected: catalogSelected,
                          compact: compact,
                          onPressed: model.multiSelectionMode
                              ? null
                              : () => _openSection(_WorkspaceSection.catalog),
                        ),
                      ),
                    Flexible(
                      child: visibleContextMenuListener(
                        ReorderableListView.builder(
                          padding: const EdgeInsets.all(YesDeskSpace.sm),
                          buildDefaultDragHandles: false,
                          shrinkWrap: true,
                          itemCount: tabs.length,
                          onReorder: model.reorder,
                          itemBuilder: (context, index) {
                            final tab = tabs[index];
                            return ReorderableDragStartListener(
                              key: ValueKey(tab),
                              index: index,
                              child: Padding(
                                padding: const EdgeInsets.only(
                                    bottom: YesDeskSpace.xs),
                                child: YesDeskNavItem(
                                  label: model.tabTooltip(tab),
                                  icon: model.tabIcon(tab),
                                  compact: compact,
                                  selected: devicesSelected &&
                                      model.currentTab == tab,
                                  onPressed: !devicesSelected
                                      ? () {
                                          _openSection(
                                              _WorkspaceSection.devices);
                                          if (!tabFixed &&
                                              !model.multiSelectionMode) {
                                            _selectTab(tab);
                                          }
                                        }
                                      : tabFixed || model.multiSelectionMode
                                          ? null
                                          : () => _selectTab(tab),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                    if (supportsSsh && tabs.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: YesDeskSpace.sm),
                        child: YesDeskNavItem(
                          icon: Icons.desktop_windows_outlined,
                          label: SshStrings(workspaceLanguage)
                              .text('Remote Desktop', 'Удалённый рабочий стол'),
                          selected: devicesSelected,
                          compact: compact,
                          onPressed: () =>
                              _openSection(_WorkspaceSection.devices),
                        ),
                      ),
                    if (supportsSsh)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: YesDeskSpace.sm),
                        child: YesDeskNavItem(
                          icon: Icons.terminal,
                          label: 'SSH / SFTP',
                          selected: sshSelected,
                          compact: compact,
                          onPressed: model.multiSelectionMode
                              ? null
                              : () => _openSection(_WorkspaceSection.ssh),
                        ),
                      ),
                    if (supportsRdp)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: YesDeskSpace.sm),
                        child: YesDeskNavItem(
                          icon: Icons.monitor_outlined,
                          label: 'Windows RDP',
                          selected: rdpSelected,
                          compact: compact,
                          onPressed: model.multiSelectionMode
                              ? null
                              : () => _openSection(_WorkspaceSection.rdp),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          if (!hidden) const VerticalDivider(width: 1),
          Expanded(
            key: const ValueKey('workspace-content'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Align(
                  alignment: Alignment.centerRight,
                  child: IconButton(
                    tooltip: labels.text(
                        'Sidebar options', 'Настройки боковой панели'),
                    onPressed: () => _showSidebarOptions(model, labels),
                    icon: const Icon(Icons.tune_rounded, size: 18),
                  ),
                ),
                Expanded(
                  child: IndexedStack(
                    index: _section.index,
                    sizing: StackFit.expand,
                    children: [
                      ExcludeFocus(
                        excluding: !devicesSelected,
                        child: LayoutBuilder(builder: (context, body) {
                          return SingleChildScrollView(
                            primary: false,
                            child: SizedBox(
                              height: math.max(body.maxHeight,
                                  MediaQuery.textScalerOf(context).scale(360)),
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(
                                    YesDeskSpace.lg,
                                    YesDeskSpace.lg,
                                    YesDeskSpace.lg,
                                    0),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Align(
                                      alignment: Alignment.centerLeft,
                                      child: ConstrainedBox(
                                        constraints:
                                            const BoxConstraints(maxWidth: 760),
                                        child: header,
                                      ),
                                    ),
                                    const SizedBox(height: YesDeskSpace.md),
                                    if (model.multiSelectionMode)
                                      createMultiSelectionBar(model)
                                    else if (tabs.isNotEmpty) ...[
                                      Text(model.tabTooltip(model.currentTab),
                                          style: Theme.of(context)
                                              .textTheme
                                              .titleMedium),
                                      Wrap(
                                        crossAxisAlignment:
                                            WrapCrossAlignment.center,
                                        children:
                                            _landscapeRightActions(context),
                                      ),
                                    ],
                                    const Divider(height: 1),
                                    _createPeersView(),
                                  ],
                                ),
                              ),
                            ),
                          );
                        }),
                      ),
                      if (_visited.contains(_WorkspaceSection.ssh))
                        ExcludeFocus(
                          excluding: !sshSelected,
                          child: _connections.ssh(workspaceLanguage),
                        )
                      else
                        const SizedBox.shrink(),
                      if (_visited.contains(_WorkspaceSection.rdp))
                        ExcludeFocus(
                          excluding: !rdpSelected,
                          child: _connections.rdp(workspaceLanguage),
                        )
                      else
                        const SizedBox.shrink(),
                      if (_visited.contains(_WorkspaceSection.catalog))
                        ExcludeFocus(
                          excluding: !catalogSelected,
                          child: _connections.catalog(workspaceLanguage,
                              visible: catalogSelected),
                        )
                      else
                        const SizedBox.shrink(),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    });
  }

  Future<void> _selectTab(int tab) async {
    await handleTabSelection(tab);
    await bind.setLocalFlutterOption(k: kOptionPeerTabIndex, v: tab.toString());
  }

  Widget _createSwitchBar(BuildContext context) {
    final model = Provider.of<PeerTabModel>(context);
    var counter = -1;
    return ReorderableListView(
        buildDefaultDragHandles: false,
        onReorder: model.reorder,
        scrollDirection: Axis.horizontal,
        physics: NeverScrollableScrollPhysics(),
        children: model.visibleEnabledOrderedIndexs.map((t) {
          final selected = model.currentTab == t;
          final color = selected
              ? MyTheme.tabbar(context).selectedTextColor
              : MyTheme.tabbar(context).unSelectedTextColor
            ?..withOpacity(0.5);
          final hover = false.obs;
          final deco = BoxDecoration(
              color: Theme.of(context).colorScheme.background,
              borderRadius: BorderRadius.circular(6));
          final decoBorder = BoxDecoration(
              border: Border(
            bottom: BorderSide(width: 2, color: color!),
          ));
          counter += 1;
          return ReorderableDragStartListener(
              key: ValueKey(t),
              index: counter,
              child: Obx(() => Tooltip(
                    preferBelow: false,
                    message: model.tabTooltip(t),
                    onTriggered: isMobile ? mobileShowTabVisibilityMenu : null,
                    child: InkWell(
                      child: Container(
                        decoration: (hover.value
                            ? (selected ? decoBorder : deco)
                            : (selected ? decoBorder : null)),
                        child: Icon(model.tabIcon(t), color: color)
                            .paddingSymmetric(horizontal: 4),
                      ).paddingSymmetric(horizontal: 4),
                      onTap: isOptionFixed(kOptionPeerTabIndex)
                          ? null
                          : () => _selectTab(t),
                      onHover: (value) => hover.value = value,
                    ),
                  )));
        }).toList());
  }

  Widget _createPeersView() {
    final model = Provider.of<PeerTabModel>(context);
    Widget child;
    if (model.visibleEnabledOrderedIndexs.isEmpty) {
      child = visibleContextMenuListener(Row(
        children: [Expanded(child: InkWell())],
      ));
    } else {
      if (model.visibleEnabledOrderedIndexs.contains(model.currentTab)) {
        child = entries[model.currentTab].widget;
      } else {
        debugPrint("should not happen! currentTab not in visibleIndexs");
        Future.delayed(Duration.zero, () {
          model.setCurrentTab(model.visibleEnabledOrderedIndexs[0]);
        });
        child = entries[0].widget;
      }
    }
    return Expanded(
        child: child.marginSymmetric(
            vertical: (isDesktop || isWebDesktop) ? 12.0 : 6.0));
  }

  Widget _createRefresh(
      {required PeerTabIndex index, required RxBool loading}) {
    final model = Provider.of<PeerTabModel>(context);
    final textColor = Theme.of(context).textTheme.titleLarge?.color;
    return Offstage(
      offstage: model.currentTab != index.index,
      child: Tooltip(
        message: translate('Refresh'),
        child: RefreshWidget(
            onPressed: () {
              if (gFFI.peerTabModel.currentTab < entries.length) {
                entries[gFFI.peerTabModel.currentTab].load?.call();
              }
            },
            spinning: loading,
            child: RotatedBox(
                quarterTurns: 2,
                child: Icon(
                  Icons.refresh,
                  size: 18,
                  color: textColor,
                ))),
      ),
    );
  }

  Widget _createPeerViewTypeSwitch(BuildContext context) {
    return PeerViewDropdown();
  }

  Widget _createMultiSelection() {
    final textColor = Theme.of(context).textTheme.titleLarge?.color;
    final model = Provider.of<PeerTabModel>(context);
    return _hoverAction(
      toolTip: translate('Select'),
      context: context,
      onTap: () {
        model.setMultiSelectionMode(true);
        if (isMobile && Navigator.canPop(context)) {
          Navigator.pop(context);
        }
      },
      child: SvgPicture.asset(
        "assets/checkbox-outline.svg",
        width: 18,
        height: 18,
        colorFilter: svgColor(textColor),
      ),
    );
  }

  void mobileShowTabVisibilityMenu() {
    final model = gFFI.peerTabModel;
    final items = List<PopupMenuItem>.empty(growable: true);
    for (int i = 0; i < PeerTabModel.maxTabCount; i++) {
      if (!model.isEnabled[i]) continue;
      items.add(PopupMenuItem(
        height: kMinInteractiveDimension * 0.8,
        onTap: isOptVisiableFixed
            ? null
            : () => model.setTabVisible(i, !model.isVisibleEnabled[i]),
        enabled: !isOptVisiableFixed,
        child: Row(
          children: [
            Checkbox(
                value: model.isVisibleEnabled[i],
                onChanged: isOptVisiableFixed
                    ? null
                    : (_) {
                        model.setTabVisible(i, !model.isVisibleEnabled[i]);
                        if (Navigator.canPop(context)) {
                          Navigator.pop(context);
                        }
                      }),
            Expanded(child: Text(model.tabTooltip(i))),
          ],
        ),
      ));
    }
    if (mobileTabContextMenuPos != null) {
      showMenu(
          context: context, position: mobileTabContextMenuPos!, items: items);
    }
  }

  Widget visibleContextMenuListener(Widget child) {
    if (!(isDesktop || isWebDesktop)) {
      return GestureDetector(
        onLongPressDown: (e) {
          final x = e.globalPosition.dx;
          final y = e.globalPosition.dy;
          mobileTabContextMenuPos = RelativeRect.fromLTRB(x, y, x, y);
        },
        onLongPressUp: () {
          mobileShowTabVisibilityMenu();
        },
        child: child,
      );
    } else {
      return Listener(
          onPointerDown: (e) {
            if (e.kind != ui.PointerDeviceKind.mouse) {
              return;
            }
            if (e.buttons == 2 &&
                !(widget.workspaceHeader != null &&
                    gFFI.peerTabModel.multiSelectionMode)) {
              showRightMenu(
                (CancelFunc cancelFunc) {
                  return visibleContextMenu(cancelFunc);
                },
                target: e.position,
              );
            }
          },
          child: child);
    }
  }

  Widget visibleContextMenu(CancelFunc cancelFunc) {
    final model = Provider.of<PeerTabModel>(context);
    final menu = List<MenuEntrySwitchSync>.empty(growable: true);
    for (int i = 0; i < model.orders.length; i++) {
      int tabIndex = model.orders[i];
      if (tabIndex < 0 || tabIndex >= PeerTabModel.maxTabCount) continue;
      if (!model.isEnabled[tabIndex]) continue;
      menu.add(MenuEntrySwitchSync(
          switchType: SwitchType.scheckbox,
          text: model.tabTooltip(tabIndex),
          currentValue: model.isVisibleEnabled[tabIndex],
          setter: (show) async {
            model.setTabVisible(tabIndex, show);
            // Do not hide the current menu (checkbox)
            // cancelFunc();
          },
          enabled: (!isOptVisiableFixed).obs));
    }
    return mod_menu.PopupMenu(
        items: menu
            .map((entry) => entry.build(
                context,
                MenuConfig(
                  commonColor: Theme.of(context).colorScheme.primary,
                  height: 20.0,
                  dividerHeight: 12.0,
                )))
            .expand((i) => i)
            .toList());
  }

  Widget createMultiSelectionBar(PeerTabModel model) {
    final children = <Widget>[
      Offstage(
        offstage: model.selectedPeers.isEmpty,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            deleteSelection(),
            addSelectionToFav(),
            addSelectionToAb(),
            editSelectionTags(),
          ],
        ),
      ),
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          selectionCount(model.selectedPeers.length),
          selectAll(model),
          closeSelection(),
        ],
      )
    ];
    if (widget.workspaceHeader != null) {
      return Wrap(
        spacing: YesDeskSpace.md,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: children,
      );
    }
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: children,
    );
  }

  Widget deleteSelection() {
    final model = Provider.of<PeerTabModel>(context);
    if (model.currentTab == PeerTabIndex.group.index) {
      return Offstage();
    }
    return _hoverAction(
        context: context,
        toolTip: translate('Delete'),
        onTap: () {
          onSubmit() async {
            final peers = model.selectedPeers;
            switch (model.currentTab) {
              case 0:
                for (var p in peers) {
                  await bind.mainRemovePeer(id: p.id);
                }
                bind.mainLoadRecentPeers();
                break;
              case 1:
                final favs = (await bind.mainGetFav()).toList();
                peers.map((p) {
                  favs.remove(p.id);
                }).toList();
                await bind.mainStoreFav(favs: favs);
                bind.mainLoadFavPeers();
                break;
              case 2:
                for (var p in peers) {
                  await bind.mainRemoveDiscovered(id: p.id);
                }
                bind.mainLoadLanPeers();
                break;
              case 3:
                await gFFI.abModel.deletePeers(peers.map((p) => p.id).toList());
                break;
              default:
                break;
            }
            gFFI.peerTabModel.setMultiSelectionMode(false);
            if (model.currentTab != 3) showToast(translate('Successful'));
          }

          deleteConfirmDialog(onSubmit, translate('Delete'));
        },
        child: Icon(Icons.delete, color: Colors.red));
  }

  Widget addSelectionToFav() {
    final model = Provider.of<PeerTabModel>(context);
    return Offstage(
      offstage:
          model.currentTab != PeerTabIndex.recent.index, // show based on recent
      child: _hoverAction(
        context: context,
        toolTip: translate('Add to Favorites'),
        onTap: () async {
          final peers = model.selectedPeers;
          final favs = (await bind.mainGetFav()).toList();
          for (var p in peers) {
            if (!favs.contains(p.id)) {
              favs.add(p.id);
            }
          }
          await bind.mainStoreFav(favs: favs);
          model.setMultiSelectionMode(false);
          showToast(translate('Successful'));
        },
        child: Icon(PeerTabModel.icons[PeerTabIndex.fav.index]),
      ).marginOnly(left: !(isDesktop || isWebDesktop) ? 11 : 6),
    );
  }

  Widget addSelectionToAb() {
    final model = Provider.of<PeerTabModel>(context);
    final addressbooks = gFFI.abModel.addressBooksCanWrite();
    if (model.currentTab == PeerTabIndex.ab.index) {
      addressbooks.remove(gFFI.abModel.currentName.value);
    }
    return Offstage(
      offstage: !gFFI.userModel.isLogin || addressbooks.isEmpty,
      child: _hoverAction(
        context: context,
        toolTip: translate('Add to address book'),
        onTap: () {
          final peers = model.selectedPeers.map((e) => Peer.copy(e)).toList();
          addPeersToAbDialog(peers);
          model.setMultiSelectionMode(false);
        },
        child: Icon(PeerTabModel.icons[PeerTabIndex.ab.index]),
      ).marginOnly(left: !(isDesktop || isWebDesktop) ? 11 : 6),
    );
  }

  Widget editSelectionTags() {
    final model = Provider.of<PeerTabModel>(context);
    return Offstage(
      offstage: !gFFI.userModel.isLogin ||
          model.currentTab != PeerTabIndex.ab.index ||
          gFFI.abModel.currentAbTags.isEmpty,
      child: _hoverAction(
              context: context,
              toolTip: translate('Edit Tag'),
              onTap: () {
                editAbTagDialog(List.empty(), (selectedTags) async {
                  final peers = model.selectedPeers;
                  await gFFI.abModel.changeTagForPeers(
                      peers.map((p) => p.id).toList(), selectedTags);
                  model.setMultiSelectionMode(false);
                  showToast(translate('Successful'));
                });
              },
              child: Icon(Icons.tag))
          .marginOnly(left: !(isDesktop || isWebDesktop) ? 11 : 6),
    );
  }

  Widget selectionCount(int count) {
    return Align(
      alignment: Alignment.center,
      child: Text('$count ${translate('Selected')}'),
    );
  }

  Widget selectAll(PeerTabModel model) {
    return Offstage(
      offstage:
          model.selectedPeers.length >= model.currentTabCachedPeers.length,
      child: _hoverAction(
        context: context,
        toolTip: translate('Select All'),
        onTap: () {
          model.selectAll();
        },
        child: Icon(Icons.select_all),
      ).marginOnly(left: 6),
    );
  }

  Widget closeSelection() {
    final model = Provider.of<PeerTabModel>(context);
    return _hoverAction(
            context: context,
            toolTip: translate('Close'),
            onTap: () {
              model.setMultiSelectionMode(false);
            },
            child: Icon(Icons.clear))
        .marginOnly(left: 6);
  }

  Widget _toggleTags() {
    return _hoverAction(
        context: context,
        toolTip: translate('Toggle Tags'),
        hoverableWhenfalse: hideAbTagsPanel,
        child: Icon(
          Icons.tag_rounded,
          size: 18,
        ),
        onTap: () async {
          await bind.mainSetLocalOption(
              key: kOptionHideAbTagsPanel,
              value: hideAbTagsPanel.value ? defaultOptionNo : "Y");
          hideAbTagsPanel.value = !hideAbTagsPanel.value;
        });
  }

  Widget _workspaceViewButtons(BuildContext context) {
    final locked = isOptionFixed(kOptionPeerCardUiType);
    Future<void> setView(PeerUiType view) async {
      peerCardUiType.value = view;
      await bind.setLocalFlutterOption(
        k: kOptionPeerCardUiType,
        v: view.index.toString(),
      );
    }

    return Obx(() {
      final isTable = peerCardUiType.value == PeerUiType.list;
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          YesDeskIconButton(
            label: translate('Device table'),
            icon: Icons.table_rows_outlined,
            selected: isTable,
            onPressed: locked ? null : () => setView(PeerUiType.list),
          ),
          YesDeskIconButton(
            label: translate('Device tiles'),
            icon: Icons.grid_view_rounded,
            selected: !isTable,
            onPressed: locked ? null : () => setView(PeerUiType.grid),
          ),
        ],
      );
    });
  }

  List<Widget> _landscapeRightActions(BuildContext context) {
    final model = Provider.of<PeerTabModel>(context);
    return [
      const PeerSearchBar().marginOnly(right: 13),
      _createRefresh(
          index: PeerTabIndex.ab, loading: gFFI.abModel.currentAbLoading),
      _createRefresh(
          index: PeerTabIndex.group, loading: gFFI.groupModel.groupLoading),
      Offstage(
        offstage: model.currentTabCachedPeers.isEmpty,
        child: _createMultiSelection(),
      ),
      if (widget.workspaceHeader != null)
        _workspaceViewButtons(context)
      else
        _createPeerViewTypeSwitch(context),
      Offstage(
        offstage: model.currentTab == PeerTabIndex.recent.index,
        child: PeerSortDropdown(),
      ),
      Offstage(
        offstage: model.currentTab != PeerTabIndex.ab.index,
        child: _toggleTags(),
      ),
    ];
  }

  List<Widget> _portraitRightActions(BuildContext context) {
    final model = Provider.of<PeerTabModel>(context);
    final screenWidth = MediaQuery.of(context).size.width;
    final leftIconSize = Theme.of(context).iconTheme.size ?? 24;
    final leftActionsSize =
        (leftIconSize + (4 + 4) * 2) * model.visibleEnabledOrderedIndexs.length;
    final availableWidth = screenWidth - 10 * 2 - leftActionsSize - 2 * 2;
    final searchWidth = 120;
    final otherActionWidth = 18 + 10;

    dropDown(List<Widget> menus) {
      final padding = 6.0;
      final textColor = Theme.of(context).textTheme.titleLarge?.color;
      return PullDownButton(
        buttonBuilder:
            (BuildContext context, Future<void> Function() showMenu) {
          return _hoverAction(
            context: context,
            toolTip: translate('More'),
            child: SvgPicture.asset(
              "assets/chevron_up_chevron_down.svg",
              width: 18,
              height: 18,
              colorFilter: svgColor(textColor),
            ),
            onTap: showMenu,
          );
        },
        routeTheme: PullDownMenuRouteTheme(
            width: menus.length * (otherActionWidth + padding * 2) * 1.0),
        itemBuilder: (context) => [
          PullDownMenuEntryImpl(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: menus
                  .map((e) =>
                      Material(child: e.paddingSymmetric(horizontal: padding)))
                  .toList(),
            ),
          )
        ],
      );
    }

    // Always show search, refresh
    List<Widget> actions = [
      const PeerSearchBar(),
      if (model.currentTab == PeerTabIndex.ab.index)
        _createRefresh(
            index: PeerTabIndex.ab, loading: gFFI.abModel.currentAbLoading),
      if (model.currentTab == PeerTabIndex.group.index)
        _createRefresh(
            index: PeerTabIndex.group, loading: gFFI.groupModel.groupLoading),
    ];
    final List<Widget> dynamicActions = [
      if (model.currentTabCachedPeers.isNotEmpty) _createMultiSelection(),
      if (model.currentTab != PeerTabIndex.recent.index) PeerSortDropdown(),
      if (model.currentTab == PeerTabIndex.ab.index) _toggleTags()
    ];
    final rightWidth = availableWidth -
        searchWidth -
        (actions.length == 2 ? otherActionWidth : 0);
    final availablePositions = rightWidth ~/ otherActionWidth;

    if (availablePositions < dynamicActions.length &&
        dynamicActions.length > 1) {
      if (availablePositions < 2) {
        actions.addAll([
          dropDown(dynamicActions),
        ]);
      } else {
        actions.addAll([
          ...dynamicActions.sublist(0, availablePositions - 1),
          dropDown(dynamicActions.sublist(availablePositions - 1)),
        ]);
      }
    } else {
      actions.addAll(dynamicActions);
    }
    return actions;
  }
}

class PeerSearchBar extends StatefulWidget {
  const PeerSearchBar({Key? key}) : super(key: key);

  @override
  State<StatefulWidget> createState() => _PeerSearchBarState();
}

class _PeerSearchBarState extends State<PeerSearchBar> {
  var drawer = false;
  final focused = false.obs;
  final focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    focusNode.addListener(() {
      focused.value = focusNode.hasFocus;
      if (focusNode.hasFocus) {
        peerSearchTextController.selection = TextSelection(
          baseOffset: 0,
          extentOffset: peerSearchTextController.text.length,
        );
      }
    });
  }

  @override
  void dispose() {
    focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return drawer
        ? _buildSearchBar()
        : _hoverAction(
            context: context,
            toolTip: translate('Search'),
            padding: const EdgeInsets.only(right: 2),
            onTap: () {
              setState(() {
                drawer = true;
              });
            },
            child: Icon(
              Icons.search_rounded,
              color: Theme.of(context).hintColor,
            ));
  }

  Widget _buildSearchBar() {
    return Obx(() => Container(
          width: stateGlobal.isPortrait.isTrue ? 120 : 140,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.background,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: [
              Expanded(
                child: Row(
                  children: [
                    Icon(
                      Icons.search_rounded,
                      color: Theme.of(context).hintColor,
                    ).marginSymmetric(horizontal: 4),
                    Expanded(
                      child: TextField(
                        autofocus: true,
                        controller: peerSearchTextController,
                        onChanged: (searchText) {
                          peerSearchText.value = searchText;
                        },
                        focusNode: focusNode,
                        textAlign: TextAlign.start,
                        maxLines: 1,
                        cursorColor: Theme.of(context)
                            .textTheme
                            .titleLarge
                            ?.color
                            ?.withOpacity(0.5),
                        cursorHeight: 18,
                        cursorWidth: 1,
                        style: const TextStyle(fontSize: 14),
                        decoration: InputDecoration(
                          contentPadding:
                              const EdgeInsets.symmetric(vertical: 6),
                          hintText:
                              focused.value ? null : translate("Search ID"),
                          hintStyle: TextStyle(
                              fontSize: 14, color: Theme.of(context).hintColor),
                          border: InputBorder.none,
                          isDense: true,
                        ),
                      ).workaroundFreezeLinuxMint(),
                    ),
                    // Icon(Icons.close),
                    IconButton(
                      alignment: Alignment.centerRight,
                      padding: const EdgeInsets.only(right: 2),
                      onPressed: () {
                        setState(() {
                          peerSearchTextController.clear();
                          peerSearchText.value = "";
                          drawer = false;
                        });
                      },
                      icon: Tooltip(
                          message: translate('Close'),
                          child: Icon(
                            Icons.close,
                            color: Theme.of(context).hintColor,
                          )),
                    ),
                  ],
                ),
              )
            ],
          ),
        ));
  }
}

class PeerViewDropdown extends StatefulWidget {
  const PeerViewDropdown({super.key});

  @override
  State<PeerViewDropdown> createState() => _PeerViewDropdownState();
}

class _PeerViewDropdownState extends State<PeerViewDropdown> {
  @override
  Widget build(BuildContext context) {
    final List<PeerUiType> types = [
      PeerUiType.grid,
      PeerUiType.tile,
      PeerUiType.list
    ];
    final style = TextStyle(
        color: Theme.of(context).textTheme.titleLarge?.color,
        fontSize: MenuConfig.fontSize,
        fontWeight: FontWeight.normal);
    List<PopupMenuEntry> items = List.empty(growable: true);
    items.add(PopupMenuItem(
        height: 36,
        enabled: false,
        child: Text(translate("Change view"), style: style)));
    for (var e in PeerUiType.values) {
      items.add(PopupMenuItem(
          height: 36,
          child: Obx(() => Center(
                child: SizedBox(
                  height: 36,
                  child: getRadio<PeerUiType>(
                      Tooltip(
                          message: translate(types.indexOf(e) == 0
                              ? 'Big tiles'
                              : types.indexOf(e) == 1
                                  ? 'Small tiles'
                                  : 'List'),
                          child: Icon(
                            e == PeerUiType.grid
                                ? Icons.grid_view_rounded
                                : e == PeerUiType.list
                                    ? Icons.view_list_rounded
                                    : Icons.view_agenda_rounded,
                            size: 18,
                          )),
                      e,
                      peerCardUiType.value,
                      dense: true,
                      isOptionFixed(kOptionPeerCardUiType)
                          ? null
                          : (PeerUiType? v) async {
                              if (v != null) {
                                peerCardUiType.value = v;
                                setState(() {});
                                await bind.setLocalFlutterOption(
                                  k: kOptionPeerCardUiType,
                                  v: peerCardUiType.value.index.toString(),
                                );
                                if (Navigator.canPop(context)) {
                                  Navigator.pop(context);
                                }
                              }
                            }),
                ),
              ))));
    }

    var menuPos = RelativeRect.fromLTRB(0, 0, 0, 0);
    return _hoverAction(
        context: context,
        toolTip: translate('Change view'),
        child: Icon(
          peerCardUiType.value == PeerUiType.grid
              ? Icons.grid_view_rounded
              : peerCardUiType.value == PeerUiType.list
                  ? Icons.view_list_rounded
                  : Icons.view_agenda_rounded,
          size: 18,
        ),
        onTapDown: (details) {
          final x = details.globalPosition.dx;
          final y = details.globalPosition.dy;
          menuPos = RelativeRect.fromLTRB(x, y, x, y);
        },
        onTap: () => showMenu(
              context: context,
              position: menuPos,
              items: items,
              elevation: 8,
            ));
  }
}

class PeerSortDropdown extends StatefulWidget {
  const PeerSortDropdown({super.key});

  @override
  State<PeerSortDropdown> createState() => _PeerSortDropdownState();
}

class _PeerSortDropdownState extends State<PeerSortDropdown> {
  _PeerSortDropdownState() {
    if (!PeerSortType.values.contains(peerSort.value)) {
      _loadLocalOptions();
    }
  }

  void _loadLocalOptions() {
    peerSort.value = PeerSortType.remoteId;
    bind.setLocalFlutterOption(
      k: kOptionPeerSorting,
      v: peerSort.value,
    );
  }

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
        color: Theme.of(context).textTheme.titleLarge?.color,
        fontSize: MenuConfig.fontSize,
        fontWeight: FontWeight.normal);
    List<PopupMenuEntry> items = List.empty(growable: true);
    items.add(PopupMenuItem(
        height: 36,
        enabled: false,
        child: Text(translate("Sort by"), style: style)));
    for (var e in PeerSortType.values) {
      items.add(PopupMenuItem(
          height: 36,
          child: Obx(() => Center(
                child: SizedBox(
                  height: 36,
                  child: getRadio(
                      Text(translate(e), style: style), e, peerSort.value,
                      dense: true, (String? v) async {
                    if (v != null) {
                      peerSort.value = v;
                      await bind.setLocalFlutterOption(
                        k: kOptionPeerSorting,
                        v: peerSort.value,
                      );
                    }
                  }),
                ),
              ))));
    }

    var menuPos = RelativeRect.fromLTRB(0, 0, 0, 0);
    return _hoverAction(
      context: context,
      toolTip: translate('Sort by'),
      child: Icon(
        Icons.sort_rounded,
        size: 18,
      ),
      onTapDown: (details) {
        final x = details.globalPosition.dx;
        final y = details.globalPosition.dy;
        menuPos = RelativeRect.fromLTRB(x, y, x, y);
      },
      onTap: () => showMenu(
        context: context,
        position: menuPos,
        items: items,
        elevation: 8,
      ),
    );
  }
}

class RefreshWidget extends StatefulWidget {
  final VoidCallback onPressed;
  final Widget child;
  final RxBool? spinning;
  const RefreshWidget(
      {super.key, required this.onPressed, required this.child, this.spinning});

  @override
  State<RefreshWidget> createState() => RefreshWidgetState();
}

class RefreshWidgetState extends State<RefreshWidget> {
  double turns = 0.0;
  bool hover = false;
  StreamSubscription<bool>? _spinningSubscription;

  @override
  void initState() {
    super.initState();
    _spinningSubscription = widget.spinning?.listen((v) {
      if (v && mounted) {
        setState(() {
          turns += 1;
        });
      }
    });
  }

  @override
  void dispose() {
    _spinningSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final deco = BoxDecoration(
      color: Theme.of(context).colorScheme.background,
      borderRadius: BorderRadius.circular(6),
    );
    return AnimatedRotation(
        turns: turns,
        duration: const Duration(milliseconds: 200),
        onEnd: () {
          if (widget.spinning?.value == true && mounted) {
            setState(() => turns += 1.0);
          }
        },
        child: Container(
          padding: EdgeInsets.all(4.0),
          margin: EdgeInsets.symmetric(horizontal: 1),
          decoration: hover ? deco : null,
          child: InkWell(
              onTap: () {
                if (mounted) setState(() => turns += 1.0);
                widget.onPressed();
              },
              onHover: (value) {
                if (mounted) {
                  setState(() {
                    hover = value;
                  });
                }
              },
              child: widget.child),
        ));
  }
}

Widget _hoverAction(
    {required BuildContext context,
    required Widget child,
    required Function() onTap,
    required String toolTip,
    GestureTapDownCallback? onTapDown,
    RxBool? hoverableWhenfalse,
    EdgeInsetsGeometry padding = const EdgeInsets.all(4.0)}) {
  final hover = false.obs;
  final deco = BoxDecoration(
    color: Theme.of(context).colorScheme.background,
    borderRadius: BorderRadius.circular(6),
  );
  return Tooltip(
    message: toolTip,
    child: Obx(
      () => Container(
          margin: EdgeInsets.symmetric(horizontal: 1),
          decoration:
              (hover.value || hoverableWhenfalse?.value == false) ? deco : null,
          child: InkWell(
              onHover: (value) => hover.value = value,
              onTap: onTap,
              onTapDown: onTapDown,
              child: Container(padding: padding, child: child))),
    ),
  );
}

class PullDownMenuEntryImpl extends StatelessWidget
    implements PullDownMenuEntry {
  final Widget child;
  const PullDownMenuEntryImpl({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return child;
  }
}
