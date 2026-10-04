import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../thumbnail_service.dart';
import 'video_backend.dart';

/// Native ExoPlayer (Media3) backend. Renders to a SurfaceView via a
/// PlatformView, so the TV gets true HDR/Dolby Vision passthrough and smooth
/// high-frame-rate playback. Control flows over a per-view MethodChannel;
/// playback state arrives over a per-view EventChannel.
class ExoVideoBackend implements VideoBackend {
  // ignore: prefer_initializing_formals
  ExoVideoBackend(this.filePath, {required bool muted}) : _muted = muted;

  static const String _viewType = 'tv_gallery/video';

  final String filePath;
  bool _muted;

  MethodChannel? _method;
  StreamSubscription<dynamic>? _eventSub;

  final _playing = StreamController<bool>.broadcast();
  final _position = StreamController<Duration>.broadcast();
  final _completed = StreamController<void>.broadcast();

  bool _connected = false; // platform view created + native reported ready
  bool _isPlaying = false;
  bool _wantPlaying = false;
  Duration _pos = Duration.zero;
  Duration _dur = Duration.zero;
  Duration? _pendingSeek;
  String? _captionDate;
  String? _captionPlace;

  @override
  Stream<bool> get playingStream => _playing.stream;
  @override
  Stream<Duration> get positionStream => _position.stream;
  @override
  Stream<void> get completedStream => _completed.stream;
  @override
  bool get isPlaying => _isPlaying;
  @override
  Duration get position => _pos;
  @override
  Duration get duration => _dur;

  void _onPlatformViewCreated(int id) {
    _method = MethodChannel('tv_gallery/video/$id');
    // The caption may have changed after the creation params were built.
    _sendCaption();
    _eventSub = EventChannel('tv_gallery/video_events/$id')
        .receiveBroadcastStream()
        .listen(_onEvent);
  }

  void _onEvent(dynamic raw) {
    final map = (raw as Map).cast<String, dynamic>();
    final value = map['value'];
    switch (map['event'] as String?) {
      case 'ready':
        _connected = true;
        if (value is int && value > 0) _dur = Duration(milliseconds: value);
        // Reconcile any state requested before the native view existed.
        _invoke('setVolume', {'volume': _muted ? 0.0 : 1.0});
        if (_pendingSeek != null) {
          _invoke('seekTo', {'ms': _pendingSeek!.inMilliseconds});
          _pendingSeek = null;
        }
        if (_wantPlaying) _invoke('play', null);
      case 'playing':
        _isPlaying = value == true;
        ThumbnailService.instance.setVideoPlaying(this, _isPlaying);
        if (!_playing.isClosed) _playing.add(_isPlaying);
      case 'position':
        if (value is int) {
          _pos = Duration(milliseconds: value);
          if (!_position.isClosed) _position.add(_pos);
        }
      case 'completed':
        if (!_completed.isClosed) _completed.add(null);
      case 'error':
      default:
        break;
    }
  }

  Future<void> _invoke(String method, Map<String, dynamic>? args) async {
    try {
      await _method?.invokeMethod<void>(method, args);
    } catch (_) {
      // View not ready / already disposed — ignore.
    }
  }

  @override
  Future<void> play() async {
    _wantPlaying = true;
    if (_connected) await _invoke('play', null);
  }

  @override
  Future<void> pause() async {
    _wantPlaying = false;
    await _invoke('pause', null);
  }

  @override
  Future<void> seek(Duration position) async {
    if (_connected) {
      await _invoke('seekTo', {'ms': position.inMilliseconds});
    } else {
      _pendingSeek = position;
    }
  }

  @override
  Future<void> setMuted(bool muted) async {
    _muted = muted;
    await _invoke('setVolume', {'volume': muted ? 0.0 : 1.0});
  }

  @override
  Future<void> stop() async {
    _wantPlaying = false;
    await _invoke('stop', null);
  }

  // Drawn natively, inside the video's own view (see VideoPlayerView.kt).
  @override
  bool get drawsCaption => true;

  @override
  Future<void> setCaption({String? date, String? place}) async {
    if (date == _captionDate && place == _captionPlace) return;
    _captionDate = date;
    _captionPlace = place;
    await _sendCaption();
  }

  Future<void> _sendCaption() =>
      _invoke('setCaption', {'date': _captionDate, 'place': _captionPlace});

  @override
  Widget buildView() {
    // Hybrid Composition: keep the SurfaceView a real SurfaceFlinger layer
    // (rendered straight to the display) rather than copying it into a Flutter
    // texture every frame. That copy is what caused the stutter and blocked HDR
    // passthrough; this path is smooth and HDR/Dolby-Vision-capable.
    return PlatformViewLink(
      viewType: _viewType,
      surfaceFactory: (context, controller) {
        return AndroidViewSurface(
          controller: controller as AndroidViewController,
          gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
          // Taps fall through to the Flutter GestureDetector wrapping this view.
          hitTestBehavior: PlatformViewHitTestBehavior.transparent,
        );
      },
      onCreatePlatformView: (params) {
        return PlatformViewsService.initExpensiveAndroidView(
          id: params.id,
          viewType: _viewType,
          layoutDirection: TextDirection.ltr,
          creationParams: {'path': filePath, 'muted': _muted},
          creationParamsCodec: const StandardMessageCodec(),
          onFocus: () => params.onFocusChanged(true),
        )
          ..addOnPlatformViewCreatedListener(params.onPlatformViewCreated)
          ..addOnPlatformViewCreatedListener(_onPlatformViewCreated)
          ..create();
      },
    );
  }

  @override
  Future<void> dispose() async {
    ThumbnailService.instance.setVideoPlaying(this, false);
    // Free the decoder right away; the platform view (and its player) is only
    // released later, which would keep it from the next video.
    unawaited(_invoke('stop', null));
    await _eventSub?.cancel();
    await _playing.close();
    await _position.close();
    await _completed.close();
    // The native view releases its ExoPlayer when the PlatformView is removed.
  }
}
