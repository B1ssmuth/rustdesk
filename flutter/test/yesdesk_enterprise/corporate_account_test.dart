import 'package:flutter/material.dart';
import 'package:flutter_hbb/yesdesk/enterprise/corporate_account.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('ordinary access is available without corporate configuration',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: CorporateAccount()),
    ));

    expect(find.text('Remote access works without a corporate account.'),
        findsOneWidget);
    final signIn = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'Sign in with corporate account'),
    );
    expect(signIn.onPressed, isNull);
    expect(find.text('Workplace directory'), findsNothing);
  });
}
