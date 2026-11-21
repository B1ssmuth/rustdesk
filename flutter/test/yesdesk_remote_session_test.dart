import 'package:flutter/material.dart';
import 'package:flutter_hbb/yesdesk/remote/session_bar.dart';
import 'package:flutter_hbb/yesdesk/remote/session_metrics.dart';
import 'package:flutter_hbb/yesdesk/remote/session_state.dart';
import 'package:flutter_hbb/yesdesk/theme.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('session commands require an active session and peer permissions', () {
    for (final active in [false, true]) {
      for (final viewOnly in [false, true]) {
        for (final keyboard in [false, true]) {
          for (final clipboard in [false, true]) {
            for (final files in [false, true]) {
              final permissions = RemoteSessionPermissions(
                active: active,
                viewOnly: viewOnly,
                keyboard: keyboard,
                clipboard: clipboard,
                files: files,
              );
              expect(permissions.canSendKeys, active && !viewOnly && keyboard);
              expect(permissions.canUseClipboard,
                  active && !viewOnly && keyboard && clipboard);
              expect(
                  permissions.canTransferFiles, active && !viewOnly && files);
            }
          }
        }
      }
    }
  });

  test('a stale frame cannot complete recovery before peer info arrives', () {
    var state = RemoteSessionRecovery.awaitingPeer;
    expect(state.onFrame(), RemoteSessionRecovery.awaitingPeer);
    state = state.onPeerInfo();
    expect(state, RemoteSessionRecovery.awaitingFrame);
    expect(state.onPeerInfo(), RemoteSessionRecovery.awaitingFrame);
    expect(state.onFrame(), RemoteSessionRecovery.ready);
  });

  test('independent delay and FPS events preserve real samples per monitor',
      () {
    final data = QualityMonitorData();
    expect(data.delay, isNull);
    expect(data.fpsForDisplay(0), isNull);

    data.update({
      'speed': '58.16kB/s',
      'fps': '{"0":0,"1":42}',
      'delay': '',
      'codec_format': 'VP9',
    });
    expect(data.fpsForDisplay(0), '0');
    expect(data.fpsForDisplay(1), '42');
    expect(data.fpsForDisplay(2), isNull);
    expect(data.fpsForDisplays(3), '0 42 –');
    expect(data.delay, isNull);

    data.update({
      'fps': '{}',
      'delay': '27',
      'target_bitrate': '1800',
    });
    expect(data.fpsForDisplay(1), '42');
    expect(data.delay, '27');
    expect(data.targetBitrate, '1800');
    expect(data.speed, '58.16kB/s');
    expect(data.codecFormat, 'VP9');
  });

  for (final brightness in Brightness.values) {
    testWidgets('toolbar hide, restore and fullscreen in ${brightness.name}',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(300, 180));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      var expanded = true;
      var fullscreen = false;
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(brightness: brightness, useMaterial3: false),
        home: YesDeskTheme(
          child: Scaffold(
            body: StatefulBuilder(builder: (context, setState) {
              return Align(
                alignment: Alignment.topCenter,
                child: YesDeskSessionBar(
                  status: expanded
                      ? const SessionBarStatus(
                          label: 'Direct and encrypted connection',
                          metrics: ['27 ms', '42 FPS', '58.16kB/s'],
                        )
                      : null,
                  controls: [
                    if (expanded)
                      for (var index = 0; index < 12; index++)
                        SessionBarAction(
                          label: 'Action $index',
                          icon: Icons.tune,
                          onPressed: () {},
                        ),
                  ],
                  windowActions: [
                    SessionBarAction(
                      label: fullscreen ? 'Exit fullscreen' : 'Fullscreen',
                      icon:
                          fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
                      onPressed: () => setState(() => fullscreen = !fullscreen),
                    ),
                    SessionBarAction(
                      label: expanded ? 'Hide toolbar' : 'Show toolbar',
                      icon: expanded
                          ? Icons.keyboard_arrow_up
                          : Icons.keyboard_arrow_down,
                      onPressed: () => setState(() => expanded = !expanded),
                    ),
                  ],
                ),
              );
            }),
          ),
        ),
      ));

      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('Fullscreen'));
      await tester.pump();
      await tester.tap(find.byTooltip('Hide toolbar'));
      await tester.pump();
      expect(find.byType(SessionBarStatus), findsNothing);
      expect(find.byTooltip('Exit fullscreen'), findsOneWidget);
      await tester.tap(find.byTooltip('Show toolbar'));
      await tester.pump();
      expect(find.text('27 ms  ·  42 FPS  ·  58.16kB/s'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
