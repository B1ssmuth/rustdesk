import 'package:flutter/material.dart';
import 'package:flutter_hbb/yesdesk/enterprise/managed_workspace.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
      'eligible corporate modes cannot launch without endpoint verification',
      (tester) async {
    final calls = <String>[];
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ManagedWorkspace(
      language: 'en',
      query: '',
      tiles: false,
      favorites: false,
      api: (path, {query, method = 'GET', body}) async {
        calls.add('$method $path');
        return switch (path) {
          '/v2/workspace' => {
              'rows': [
                {
                  'device_id': 'pilot',
                  'hostname': 'Pilot PC',
                  'agent_registered': true,
                  'metadata': <String, dynamic>{},
                  'ou_path': [],
                  'group_name': '',
                  'favorite': false
                },
              ],
              'ou_paths': [],
              'has_next': false,
              'sync': null,
            },
          '/v2/devices/pilot/history' => [],
          '/v2/devices/pilot/connection-options' => {
              'attended': {'eligible': true, 'available': false},
              'unattended': {'eligible': true, 'available': false},
            },
          _ => throw StateError('Unexpected request'),
        };
      },
    ))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pilot PC'));
    await tester.pumpAndSettle();
    expect(find.textContaining('With confirmation'), findsOneWidget);
    expect(find.textContaining('Corporate access · blocked'), findsOneWidget);
    final connect = find.widgetWithText(FilledButton, 'Connect');
    expect(tester.widget<FilledButton>(connect).onPressed, isNull);
    expect(calls.where((call) => call.startsWith('POST ')), isEmpty);
  });
}
