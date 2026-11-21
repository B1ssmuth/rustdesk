import 'dart:convert';

/// Samples from RustDesk's `update_quality_status` events. Video and delay
/// events are emitted independently and only populate their own fields.
class QualityMonitorData {
  String? speed;
  String? delay;
  String? targetBitrate;
  String? codecFormat;
  String? chroma;
  String? fps;

  Map<String, dynamic> _fpsByDisplay = const {};

  String? fpsForDisplay(int display) =>
      _fpsByDisplay[display.toString()]?.toString();

  String? fpsForDisplays(int count) => _fpsByDisplay.isEmpty
      ? null
      : [for (var i = 0; i < count; i++) fpsForDisplay(i) ?? '–'].join(' ');

  void update(Map<String, dynamic> event) {
    speed = _sample(event['speed']) ?? speed;
    delay = _sample(event['delay']) ?? delay;
    targetBitrate = _sample(event['target_bitrate']) ?? targetBitrate;
    codecFormat = _sample(event['codec_format']) ?? codecFormat;
    chroma = _sample(event['chroma']) ?? chroma;

    final eventFps = _sample(event['fps']);
    if (eventFps == null) return;
    final decoded = jsonDecode(eventFps);
    if (decoded is! Map<String, dynamic> || decoded.isEmpty) return;
    _fpsByDisplay = decoded;
  }

  static String? _sample(Object? value) =>
      value is String && value.isNotEmpty ? value : null;
}
