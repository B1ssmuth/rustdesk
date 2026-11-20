import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

abstract final class YesDeskIdentity {
  static const name = 'YES Desk';
  static const website = 'https://yesapart.com/';
  static const source = 'https://github.com/B1ssmuth/rustdesk';
  static const support = '$source/issues';
  static const releases = '$source/releases';
}

void registerYesDeskLicenses() {
  LicenseRegistry.addLicense(() async* {
    final license = await rootBundle.loadString('assets/LICENSE-AGPL-3.0.txt');
    yield LicenseEntryWithLineBreaks(
        ['YES Desk / RustDesk (AGPL-3.0)'], license);
  });
}
