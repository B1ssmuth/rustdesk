import 'package:flutter/widgets.dart';

class DesktopConnections {
  DesktopConnections({required VoidCallback showSsh});

  Widget catalog(String language,
          {required bool visible,
          bool unified = false,
          bool allowProfessional = true,
          bool managementAvailable = false}) =>
      const SizedBox.shrink();

  Widget ssh(String language) => const SizedBox.shrink();

  Widget rdp(String language) => const SizedBox.shrink();

  void refreshSsh() {}

  void refreshRdp() {}

  void dispose() {}
}
