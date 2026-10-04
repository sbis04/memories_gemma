import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/video_tuning.dart';
import 'video_backend.dart';

/// media_kit (libmpv) backend — used on non-Android platforms (e.g. macOS for
/// development). Renders into a Flutter texture, so it tone-maps HDR to SDR
/// rather than passing it through, but it's portable and handles most formats.
class MediaKitVideoBackend implements VideoBackend {
  MediaKitVideoBackend(this.filePath, {required bool muted}) {
    // ignore: discarded_futures
    _open(muted);
  }

  final String filePath;
  final Player _player = Player();
  late final VideoController _controller = VideoController(_player);

  Future<void> _open(bool muted) async {
    await tuneForSmoothPlayback(_player);
    await _player.setVolume(muted ? 0 : 100);
    await _player.open(Media(filePath), play: false);
  }

  @override
  Stream<bool> get playingStream => _player.stream.playing;
  @override
  Stream<Duration> get positionStream => _player.stream.position;
  @override
  Stream<void> get completedStream =>
      _player.stream.completed.where((done) => done).map((_) {});
  @override
  bool get isPlaying => _player.state.playing;
  @override
  Duration get position => _player.state.position;
  @override
  Duration get duration => _player.state.duration;

  @override
  Future<void> play() => _player.play();
  @override
  Future<void> pause() => _player.pause();
  @override
  Future<void> seek(Duration position) => _player.seek(position);
  @override
  Future<void> setMuted(bool muted) => _player.setVolume(muted ? 0 : 100);

  @override
  Future<void> stop() => _player.pause();

  // Rendered into a Flutter texture: a normal Flutter overlay is fine here.
  @override
  bool get drawsCaption => false;

  @override
  Future<void> setCaption({String? date, String? place}) async {}

  @override
  Widget buildView() => Video(
        controller: _controller,
        controls: NoVideoControls,
        fit: BoxFit.contain,
      );

  @override
  Future<void> dispose() => _player.dispose();
}
