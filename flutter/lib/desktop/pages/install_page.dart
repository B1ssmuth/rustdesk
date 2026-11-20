import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/desktop/widgets/tabbar_widget.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/models/state_model.dart';
import 'package:get/get.dart';
import 'package:path/path.dart';
import 'package:flutter_hbb/yesdesk/widgets.dart';
import 'package:window_manager/window_manager.dart';

class InstallPage extends StatefulWidget {
  const InstallPage({Key? key}) : super(key: key);

  @override
  State<InstallPage> createState() => _InstallPageState();
}

class _InstallPageState extends State<InstallPage> {
  final tabController = DesktopTabController(tabType: DesktopTabType.main);

  _InstallPageState() {
    Get.put<DesktopTabController>(tabController);
    const label = "install";
    tabController.add(TabInfo(
        key: label,
        label: label,
        closable: false,
        page: _InstallPageBody(
          key: const ValueKey(label),
        )));
  }

  @override
  void dispose() {
    super.dispose();
    Get.delete<DesktopTabController>();
  }

  @override
  Widget build(BuildContext context) {
    return DragToResizeArea(
      resizeEdgeSize: stateGlobal.resizeEdgeSize.value,
      enableResizeEdges: windowManagerEnableResizeEdges,
      child: Container(
        child: Scaffold(
            backgroundColor: Theme.of(context).colorScheme.background,
            body: DesktopTab(controller: tabController)),
      ),
    );
  }
}

class _InstallPageBody extends StatefulWidget {
  const _InstallPageBody({Key? key}) : super(key: key);

  @override
  State<_InstallPageBody> createState() => _InstallPageBodyState();
}

class _InstallPageBodyState extends State<_InstallPageBody>
    with WindowListener {
  final _installationError = ''.obs;
  late final TextEditingController controller;
  final RxBool startmenu = true.obs;
  final RxBool desktopicon = true.obs;
  final RxBool printer = true.obs;
  final RxBool showProgress = false.obs;
  final RxBool btnEnabled = true.obs;

  // todo move to theme.
  final buttonStyle = OutlinedButton.styleFrom(
    textStyle: TextStyle(fontSize: 14, fontWeight: FontWeight.normal),
    padding: EdgeInsets.symmetric(vertical: 15, horizontal: 12),
  );

  _InstallPageBodyState() {
    controller = TextEditingController(text: bind.installInstallPath());
    final installOptions = jsonDecode(bind.installInstallOptions());
    startmenu.value = installOptions['STARTMENUSHORTCUTS'] != '0';
    desktopicon.value = installOptions['DESKTOPSHORTCUTS'] != '0';
    printer.value = installOptions['PRINTER'] != '0';
  }

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    controller.dispose();
    super.dispose();
  }

  @override
  void onWindowClose() {
    if (showProgress.value) return;
    gFFI.close();
    super.onWindowClose();
    windowManager.setPreventClose(false);
    windowManager.close();
  }

  InkWell Option(RxBool option, {String label = ''}) {
    return InkWell(
      // todo mouseCursor: "SystemMouseCursors.forbidden" or no cursor on btnEnabled == false
      borderRadius: BorderRadius.circular(6),
      onTap: () => btnEnabled.value ? option.value = !option.value : null,
      child: Row(
        children: [
          Obx(
            () => Checkbox(
              visualDensity: VisualDensity.standard,
              value: option.value,
              onChanged: (v) =>
                  btnEnabled.value ? option.value = !option.value : null,
            ).marginOnly(right: 8),
          ),
          Expanded(
            child: Text(translate(label)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final double em = 13;
    return Scaffold(
        backgroundColor: null,
        body: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('$appName · ${translate('Installation')}',
                  style: Theme.of(context).textTheme.titleLarge),
              Row(
                children: [
                  Text('${translate('Installation Path')}:')
                      .marginOnly(right: 10),
                  Expanded(
                    child: TextField(
                      controller: controller,
                      readOnly: true,
                      decoration: InputDecoration(
                        contentPadding: EdgeInsets.all(0.75 * em),
                      ),
                    ).workaroundFreezeLinuxMint().marginOnly(right: 10),
                  ),
                  if (appName != 'YES Desk')
                    Obx(
                      () => OutlinedButton.icon(
                        icon: Icon(Icons.folder_outlined, size: 16),
                        onPressed: btnEnabled.value ? selectInstallPath : null,
                        style: buttonStyle,
                        label: Text(translate('Change Path')),
                      ),
                    )
                ],
              ).marginSymmetric(vertical: 2 * em),
              Option(startmenu, label: 'Create start menu shortcuts')
                  .marginOnly(bottom: 7),
              Option(desktopicon, label: 'Create desktop icon')
                  .marginOnly(bottom: 7),
              Option(printer, label: 'Install {$appName} Printer'),
              YesDeskPanel(
                child: ListTile(
                  leading: const Icon(Icons.description_outlined),
                  title: Text(translate('Open Source Licenses')),
                  subtitle: Text(translate('yesdesk_install_license_tip')),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => showLicensePage(
                    context: context,
                    applicationName: appName,
                    applicationLegalese: translate('yesdesk_upstream_notice'),
                  ),
                ),
              ).marginSymmetric(vertical: 2 * em),
              Obx(() => _installationError.value.isEmpty
                  ? const SizedBox.shrink()
                  : Semantics(
                      liveRegion: true,
                      child: Text(
                        _installationError.value,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error),
                      ).marginOnly(bottom: 12),
                    )),
              Row(
                children: [
                  Expanded(
                    // NOT use Offstage to wrap LinearProgressIndicator
                    child: Obx(() => showProgress.value
                        ? LinearProgressIndicator().marginOnly(right: 10)
                        : Offstage()),
                  ),
                  Obx(
                    () => OutlinedButton.icon(
                      icon: Icon(Icons.close_rounded, size: 16),
                      label: Text(translate('Cancel')),
                      onPressed:
                          btnEnabled.value ? () => windowManager.close() : null,
                      style: buttonStyle,
                    ).marginOnly(right: 10),
                  ),
                  Obx(
                    () => ElevatedButton.icon(
                      icon: Icon(Icons.done_rounded, size: 16),
                      label: Text(translate('Accept and Install')),
                      onPressed: btnEnabled.value ? install : null,
                      style: buttonStyle,
                    ),
                  ),
                  Offstage(
                    offstage: bind.installShowRunWithoutInstall(),
                    child: Obx(
                      () => OutlinedButton.icon(
                        icon: Icon(Icons.screen_share_outlined, size: 16),
                        label: Text(translate('Run without install')),
                        onPressed: btnEnabled.value
                            ? () => bind.installRunWithoutInstall()
                            : null,
                        style: buttonStyle,
                      ).marginOnly(left: 10),
                    ),
                  ),
                ],
              )
            ],
          ).paddingSymmetric(horizontal: 4 * em, vertical: 3 * em),
        ));
  }

  Future<void> install() async {
    btnEnabled.value = false;
    showProgress.value = true;
    _installationError.value = '';
    final options = [
      if (startmenu.value) 'startmenu',
      if (desktopicon.value) 'desktopicon',
      if (printer.value) 'printer',
    ].join(' ');
    try {
      final error =
          await bind.installInstallMe(options: options, path: controller.text);
      if (!mounted) return;
      showProgress.value = false;
      if (error.isEmpty) {
        await windowManager.close();
      } else {
        _installationError.value = error;
      }
    } catch (error) {
      if (mounted) {
        _installationError.value =
            '${translate('Installation failed!')} ($error)';
      }
    } finally {
      if (mounted) {
        btnEnabled.value = true;
        showProgress.value = false;
      }
    }
  }

  void selectInstallPath() async {
    String? install_path = await FilePicker.platform
        .getDirectoryPath(initialDirectory: controller.text);
    if (install_path != null) {
      controller.text = join(install_path, await bind.mainGetAppName());
    }
  }
}
