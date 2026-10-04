import 'package:media_kit/media_kit.dart';

/// Tunes libmpv for nicer playback on the TV. Best-effort — any unsupported
/// property is ignored.
///
/// - **Frame pacing:** mpv defaults to syncing video to the audio clock
///   (`video-sync=audio`) and dropping late frames, which makes 50/60fps clips
///   skip unevenly on a modest TV. `display-resample` paces frames to the
///   display's refresh cadence so high-frame-rate footage plays smoothly.
/// - **HDR:** we render into Flutter's SDR texture (no HDR passthrough to the
///   panel is possible via that path), so HDR10/HLG content — and the HDR10
///   base layer of Dolby Vision — is tone-mapped to SDR; otherwise it looks
///   washed-out/grey. (Dolby Vision profile 5 has no HDR10 base layer, so
///   libmpv can't render it correctly regardless.)
Future<void> tuneForSmoothPlayback(Player player) async {
  final platform = player.platform;
  if (platform == null) return;

  Future<void> set(String key, String value) async {
    try {
      // ignore: avoid_dynamic_calls
      await (platform as dynamic).setProperty(key, value);
    } catch (_) {
      // Property unavailable on this platform/build — ignore.
    }
  }

  await set('video-sync', 'display-resample');
  await set('tone-mapping', 'bt.2390');
  await set('hdr-compute-peak', 'yes');
}
