import 'dart:io' show Platform;

import 'package:flutter/widgets.dart';

import 'exo_backend.dart';
import 'media_kit_backend.dart';

/// Abstracts the video engine so the viewer/slideshow UI is identical across
/// platforms. On Android we use native ExoPlayer rendered to a SurfaceView
/// (true HDR/Dolby Vision passthrough + smooth high-frame-rate playback); on
/// other platforms (e.g. macOS during development) we fall back to media_kit.
abstract class VideoBackend {
  /// Creates the right backend for the current platform. [filePath] is a local
  /// file path; playback starts paused until [play] is called.
  factory VideoBackend(String filePath, {required bool muted}) {
    if (Platform.isAndroid) return ExoVideoBackend(filePath, muted: muted);
    return MediaKitVideoBackend(filePath, muted: muted);
  }

  /// Emits when playback starts/stops.
  Stream<bool> get playingStream;

  /// Emits the current position a few times per second while playing.
  Stream<Duration> get positionStream;

  /// Emits once each time the clip plays to the end.
  Stream<void> get completedStream;

  bool get isPlaying;
  Duration get position;
  Duration get duration;

  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> setMuted(bool muted);

  /// Stops and frees the decoder (hardware decoders are scarce on a TV); a
  /// later [play] prepares again.
  Future<void> stop();

  /// Whether [setCaption] draws the date/place caption on the video itself.
  /// When true, callers must not overlay a Flutter caption on the video (on
  /// Android, a Flutter layer over the native video surface forces the TV to
  /// GPU-composite every frame and 4K/60fps playback drops most frames).
  bool get drawsCaption;

  /// Sets the lower-left caption ([place] above [date]); nulls hide it.
  Future<void> setCaption({String? date, String? place});

  /// The widget that renders the video frames.
  Widget buildView();

  Future<void> dispose();
}
