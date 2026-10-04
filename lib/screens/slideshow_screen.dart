import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../models/media_entry.dart';
import '../services/settings_controller.dart';
import '../services/location_service.dart';
import '../services/thumbnail_service.dart';
import '../services/video/video_backend.dart';
import '../widgets/ask_panel.dart';
import '../widgets/media_caption.dart';
import '../widgets/zoomable_image.dart';

/// Slideshow images are decoded a touch below full quality so slides load
/// faster (the full-quality path is reserved for the single-photo viewer).
const int _slideImageQuality = 95;

/// A dedicated, immersive slideshow player with selectable transitions
/// (fade / Ken Burns / slide), loop and shuffle. Images advance on the chosen
/// interval; videos play to the end and then advance.
class SlideshowScreen extends StatefulWidget {
  const SlideshowScreen({
    super.key,
    required this.media,
    required this.startIndex,
    this.folderPath,
  });

  final List<MediaEntry> media;
  final int startIndex;

  /// The folder this slideshow is playing from, persisted so the folder can
  /// offer to resume the slideshow later. Null if launched without a folder.
  final String? folderPath;

  @override
  State<SlideshowScreen> createState() => _SlideshowScreenState();
}

class _SlideshowScreenState extends State<SlideshowScreen> {
  final _settings = SettingsController.instance;
  late List<int> _order;
  int _pos = 0;
  bool _paused = false;
  bool _controls = true;

  /// Paused and untouched for a while: the controls and caption fade out so
  /// nothing static sits on the TV (burn-in). Any key brings them back.
  bool _idle = false;

  // Zoom on a paused photo (OK steps, arrows pan) — same as the viewer.
  late final ZoomController _zoom = ZoomController()..addListener(_onZoom);
  bool _wasZoomed = false;
  bool _zoomHint = false;
  Timer? _zoomHintTimer;

  /// Briefly shows how to get around once a photo is zoomed in.
  void _onZoom() {
    final zoomed = _zoom.isZoomed;
    if (zoomed == _wasZoomed) return;
    _wasZoomed = zoomed;
    _zoomHintTimer?.cancel();
    setState(() => _zoomHint = zoomed);
    if (zoomed) {
      _zoomHintTimer = Timer(const Duration(milliseconds: 2500), () {
        if (mounted) setState(() => _zoomHint = false);
      });
    }
  }

  // Focus: the slide itself (remote keys) vs. the top-bar chips (Up).
  final FocusNode _bodyFocus = FocusNode(debugLabel: 'slideshowBody');
  final FocusNode _exitFocus = FocusNode(debugLabel: 'slideshowExit');
  final FocusNode _playFocus = FocusNode(debugLabel: 'slideshowPlay');
  final FocusNode _askFocus = FocusNode(debugLabel: 'slideshowAsk');
  bool _prebuffering = false;
  Timer? _timer;
  Timer? _hideTimer;
  Timer? _prebufferTimer;
  String? _placeName; // reverse-geocoded location for the current slide

  @override
  void initState() {
    super.initState();
    final n = widget.media.length;
    if (_settings.slideshowShuffle) {
      final indices = List<int>.generate(n, (i) => i)
        ..shuffle(Random(widget.startIndex))
        ..remove(widget.startIndex);
      _order = [widget.startIndex, ...indices];
    } else if (_settings.slideshowLoop) {
      // Looping: play the whole folder, starting at the current item, wrapping.
      _order = [for (var i = 0; i < n; i++) (widget.startIndex + i) % n];
    } else {
      // Not looping: play from the current item through to the last, then stop
      // — so the counter reads the item's real position and ends at "n / n".
      _order = [for (var i = widget.startIndex; i < n; i++) i];
    }
    // Keep the display awake for the duration of the slideshow so the TV
    // doesn't dim or enter power-saving while watching.
    unawaited(WakelockPlus.enable());
    _schedule();
    _scheduleHideControls();
    _schedulePrebuffer();
    _resolvePlace();
    _saveResumePoint();
  }

  /// Reverse-geocodes the current slide for the caption (ignores stale results
  /// if the slideshow has already advanced).
  Future<void> _resolvePlace() async {
    final entry = _current;
    if (mounted) setState(() => _placeName = null);
    final place = await LocationService.instance.placeName(entry);
    if (mounted && identical(_current, entry)) {
      setState(() => _placeName = place);
    }
  }

  /// Queues prefetching of the upcoming items — but never during a video
  /// slide: decoding full-size photos (HEIC uses the same hardware decoder as
  /// the video, plus CPU and image-cache churn) made playback stutter in a
  /// play/freeze cycle. Photo slides already prefetch several ahead, so the
  /// slides after a video are normally ready before it starts.
  void _schedulePrebuffer() {
    _prebufferTimer?.cancel();
    if (_current.isVideo) return;
    _prebufferTimer = Timer(Duration.zero, () {
      // ignore: discarded_futures
      _prebufferAhead();
    });
  }

  /// Generates and decodes the next few items ahead of time so a slide is ready
  /// before it's shown — the loading indicator should never appear mid-show.
  /// Runs *sequentially* (one decode at a time) so the work is spread out
  /// instead of spiking, which keeps any concurrently-playing video smooth.
  Future<void> _prebufferAhead() async {
    if (_prebuffering) return;
    _prebuffering = true;
    try {
      const ahead = 5;
      final n = _order.length;
      // Decode the next few full images into the Flutter cache, sequentially so
      // the work is spread out (no spike) and a slide is ready before shown.
      for (var i = 1; i <= ahead; i++) {
        if (!mounted) return;
        final pos = _pos + i;
        if (pos >= n && !_settings.slideshowLoop) break;
        final entry = widget.media[_order[pos % n]];
        if (entry.isImage) await _prebufferOne(entry);
      }
    } finally {
      _prebuffering = false;
    }
  }

  Future<void> _prebufferOne(MediaEntry entry) async {
    final f = await ThumbnailService.instance
        .fullImage(entry, quality: _slideImageQuality);
    if (f != null && mounted) {
      await precacheImage(FileImage(f), context);
    }
  }

  @override
  void dispose() {
    _zoomHintTimer?.cancel();
    _zoom.dispose();
    _bodyFocus.dispose();
    _exitFocus.dispose();
    _playFocus.dispose();
    _askFocus.dispose();
    unawaited(WakelockPlus.disable());
    // Remember where this slideshow stopped so the folder can offer to resume.
    if (widget.folderPath != null) {
      unawaited(_settings.setLastSlideshow(
        folder: widget.folderPath,
        item: _current.path,
      ));
    }
    _timer?.cancel();
    _hideTimer?.cancel();
    _prebufferTimer?.cancel();
    super.dispose();
  }

  int get _index => _order[_pos];
  MediaEntry get _current => widget.media[_index];

  /// Leaves the slideshow, returning the item it stopped on so the caller can
  /// open that photo (instead of the one the slideshow started from).
  void _exit() => Navigator.of(context).pop(_index);

  /// "current / total" for the counter. In shuffle there's no meaningful
  /// absolute position so it tracks progress through the shuffled sequence;
  /// otherwise it shows the item's real position in the folder (so starting at
  /// item 50 of 100 reads "50 / 100" and counts up to "100 / 100").
  String get _counterLabel {
    final total = widget.media.length;
    final current = _settings.slideshowShuffle ? _pos + 1 : _index + 1;
    return '$current / $total';
  }

  /// While playing the controls hide after a moment. While paused they stay
  /// up (so it's clearly paused, not stuck) — until 10s without a key press,
  /// when they and the caption fade out to avoid burn-in.
  void _scheduleHideControls() {
    _hideTimer?.cancel();
    _hideTimer = Timer(
        _paused
            ? const Duration(seconds: 10)
            : const Duration(milliseconds: 2500), () {
      if (!mounted) return;
      setState(() {
        _controls = false;
        _idle = _paused;
      });
      // Don't leave focus on a hidden chip.
      if (!_bodyFocus.hasFocus) _bodyFocus.requestFocus();
    });
  }

  void _wake() {
    if (!_controls || _idle) {
      setState(() {
        _controls = true;
        _idle = false;
      });
    }
    _scheduleHideControls();
  }

  void _schedule() {
    _timer?.cancel();
    if (_paused) return;
    if (_current.isImage) {
      _timer = Timer(
        Duration(seconds: _settings.slideshowSeconds),
        // ignore: discarded_futures
        _autoAdvance,
      );
    }
    // Videos advance from their own end callback.
  }

  /// Auto-advance: when the interval is up, wait until the next image is
  /// actually decoded before moving on, so a slide never flashes a loading
  /// indicator. (Manual Left/Right still advances immediately.)
  Future<void> _autoAdvance() async {
    if (_paused || !mounted) return;
    final n = _order.length;
    final nextPos = _pos + 1;
    if (nextPos >= n && !_settings.slideshowLoop) {
      _exit();
      return;
    }
    final nextEntry = widget.media[_order[nextPos % n]];
    // Wait until the next image is decoded so a slide never flashes a loading
    // indicator mid-show.
    if (nextEntry.isImage) {
      await _prebufferOne(nextEntry);
      if (!mounted || _paused) return; // exited / paused while we waited
    }
    _next();
  }

  void _go(int delta) {
    _zoom.reset();
    _leavingVideo = _current.isVideo;
    final next = _pos + delta;
    if (next < 0) {
      if (_settings.slideshowLoop) {
        _pos = _order.length - 1;
      } else {
        return;
      }
    } else if (next >= _order.length) {
      if (_settings.slideshowLoop) {
        _pos = 0;
      } else {
        _exit();
        return;
      }
    } else {
      _pos = next;
    }
    setState(() {});
    _schedule();
    _schedulePrebuffer();
    _resolvePlace();
    _saveResumePoint();
  }

  /// Saves the resume point on every slide change — not just on exit — so an
  /// abrupt close (crash, TV switched off) still resumes here. It's the slide
  /// *before* the current one, so the slide that was showing is replayed in
  /// full. (A normal exit then records the slide stopped on; see [dispose].)
  void _saveResumePoint() {
    final folder = widget.folderPath;
    if (folder == null) return;
    final previous = widget.media[_order[_pos > 0 ? _pos - 1 : _pos]];
    unawaited(_settings.setLastSlideshow(
        folder: folder, item: previous.path, notify: false));
  }

  void _next() => _go(1);

  /// Pauses (if needed) and asks Gemini about the current slide — the
  /// zoomed-in part of it, if zoomed.
  Future<void> _ask() async {
    if (!_paused) _togglePause();
    _hideTimer?.cancel();
    await showAskPanel(context, _current,
        focus: _current.isImage ? _zoom.visibleRegion : null);
    if (!mounted) return;
    _bodyFocus.requestFocus();
    _wake();
  }

  /// Remote keys on the slide itself. Playing: OK pauses, Left/Right change
  /// slides. Paused on a photo it behaves like the viewer: OK steps zoom,
  /// arrows pan while zoomed. Up goes to the top-bar chips, Down asks Gemini.
  static final _okKeys = {
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.numpadEnter,
    LogicalKeyboardKey.space,
    LogicalKeyboardKey.select,
  };
  bool _okDown = false;
  bool _okHeld = false;

  /// OK on the slide: a press (acted on release) pauses, or — paused on a
  /// photo — steps zoom. Holding it opens the top bar on Ask from anywhere.
  KeyEventResult _onOk(KeyEvent event) {
    switch (event) {
      case KeyDownEvent():
        _okDown = true;
        _okHeld = false;
        _wake();
      case KeyRepeatEvent():
        if (_okDown && !_okHeld) {
          _okHeld = true;
          _wake();
          _askFocus.requestFocus();
        }
      case KeyUpEvent():
        if (_okDown && !_okHeld) {
          if (_paused && _current.isImage) {
            _zoom.cycle();
          } else {
            _togglePause();
          }
        }
        _okDown = false;
    }
    return KeyEventResult.handled;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    // Keys from the top-bar chips bubble through here — let them reach the
    // chips' own activation and directional focus.
    if (!_bodyFocus.hasPrimaryFocus) return KeyEventResult.ignored;
    if (_okKeys.contains(event.logicalKey)) return _onOk(event);
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    _wake();
    final zoomed = _zoom.isZoomed;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowLeft:
        zoomed ? _zoom.pan(const Offset(1, 0)) : _go(-1);
      case LogicalKeyboardKey.arrowRight:
        zoomed ? _zoom.pan(const Offset(-1, 0)) : _go(1);
      case LogicalKeyboardKey.arrowUp:
        // Zoomed: pan; at the top edge, reach the top bar (on Ask).
        if (!zoomed) {
          _playFocus.requestFocus();
        } else if (!_zoom.pan(const Offset(0, 1))) {
          _askFocus.requestFocus();
        }
      case LogicalKeyboardKey.arrowDown:
        // Zoomed: pan; at the bottom edge, ask about the zoomed-in part.
        if (!zoomed || !_zoom.pan(const Offset(0, -1))) unawaited(_ask());
      case LogicalKeyboardKey.mediaPlayPause:
      case LogicalKeyboardKey.mediaPlay:
      case LogicalKeyboardKey.mediaPause:
        _togglePause();
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  /// Keys on the top-bar chips: Down returns to the slide.
  KeyEventResult _onControlsKey(FocusNode node, KeyEvent event) {
    // A still-held OK (from the hold that opened this bar) must not activate
    // the chip it landed on.
    if (event is KeyRepeatEvent && _okKeys.contains(event.logicalKey)) {
      return KeyEventResult.handled;
    }
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    _wake();
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _bodyFocus.requestFocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Video slides on Android draw the caption natively (see [_SlideVideo]).
  bool get _videoDrawsCaption => _current.isVideo && Platform.isAndroid;

  /// Whether the slide being left was a video (see the cut in [build]).
  bool _leavingVideo = false;

  void _togglePause() {
    setState(() => _paused = !_paused);
    if (!_paused) _zoom.reset(); // resuming plays at fit
    _wake();
    if (_paused) {
      _timer?.cancel();
    } else {
      _schedule();
    }
  }

  @override
  Widget build(BuildContext context) {
    final transition = _settings.slideshowTransition;
    // Cut (no cross-fade/slide) into or out of a video: during a transition
    // both slides are alive, so two players would hold the hardware decoder at
    // once (and a native video surface doesn't fade cleanly) — playback
    // stuttered, worst between consecutive videos.
    final cut = _current.isVideo || _leavingVideo;
    final dur = switch (transition) {
      _ when cut => const Duration(milliseconds: 1),
      SlideshowTransition.none => const Duration(milliseconds: 1),
      SlideshowTransition.slide => const Duration(milliseconds: 600),
      _ => const Duration(milliseconds: 900),
    };

    Widget slide;
    if (_current.isVideo) {
      slide = _SlideVideo(
        key: ValueKey('v$_index'),
        entry: _current,
        onEnd: _next,
        muted: _settings.muteVideo,
        paused: _paused,
        captionDate: _settings.showCaption
            ? MediaCaption.formatDate(_current.modified)
            : null,
        captionPlace: _settings.showCaption ? _placeName : null,
      );
    } else {
      slide = _SlideImage(
        key: ValueKey('i$_index'),
        entry: _current,
        zoom: _zoom,
        kenBurns: transition == SlideshowTransition.kenBurns,
        duration: Duration(seconds: _settings.slideshowSeconds + 1),
        seed: _index,
      );
    }

    return PopScope(
      // Intercept Back so we can return the item the slideshow stopped on.
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (_zoom.isZoomed) {
          _zoom.reset(); // Back returns a zoomed photo to fit first
          _wake();
        } else {
          _exit();
        }
      },
      child: Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        focusNode: _bodyFocus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: MouseRegion(
            onHover: (_) => _wake(),
            child: GestureDetector(
              onTap: _togglePause,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  AnimatedSwitcher(
                    duration: dur,
                    switchInCurve: Curves.easeOut,
                    switchOutCurve: Curves.easeIn,
                    transitionBuilder: (child, animation) =>
                        _transitionFor(transition, child, animation),
                    child: slide,
                  ),
                  // Date + location caption (toggle in Settings). Stays visible
                  // through the show, independent of the auto-hiding controls —
                  // except over videos: any Flutter layer on top of the native
                  // video surface forces the TV to GPU-composite every frame,
                  // which dropped most frames of 4K/60fps (HDR) clips.
                  if (_settings.showCaption && !_videoDrawsCaption)
                    Positioned(
                      left: 20,
                      bottom: 18,
                      child: AnimatedOpacity(
                        opacity: _idle ? 0 : 1,
                        duration: const Duration(milliseconds: 600),
                        child: MediaCaption(
                          date: _current.modified,
                          place: _placeName,
                        ),
                      ),
                    ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 28,
                    child: Center(child: ZoomHint(visible: _zoomHint)),
                  ),
                  _buildControls(context),
                ],
              ),
            ),
          ),
      ),
      ),
    );
  }

  Widget _transitionFor(
      SlideshowTransition t, Widget child, Animation<double> a) {
    switch (t) {
      case SlideshowTransition.slide:
        return SlideTransition(
          position: Tween(begin: const Offset(0.12, 0), end: Offset.zero)
              .animate(a),
          child: FadeTransition(opacity: a, child: child),
        );
      case SlideshowTransition.none:
        return child;
      case SlideshowTransition.fade:
      case SlideshowTransition.kenBurns:
        return FadeTransition(opacity: a, child: child);
    }
  }

  Widget _buildControls(BuildContext context) {
    return IgnorePointer(
      ignoring: !_controls,
      child: AnimatedOpacity(
        opacity: _controls ? 1 : 0,
        duration: const Duration(milliseconds: 250),
        child: Container(
          // No backdrop gradient over the photo — buttons have their own
          // pills and text a soft shadow.
          padding: const EdgeInsets.fromLTRB(28, 22, 28, 40),
          alignment: Alignment.topCenter,
          child: Focus(
            canRequestFocus: false,
            skipTraversal: true,
            onKeyEvent: _onControlsKey,
            child: FocusTraversalGroup(
              child: Row(
            children: [
              _GlassChip(
                icon: LucideIcons.x,
                label: 'Exit',
                onTap: _exit,
                focusNode: _exitFocus,
              ),
              const SizedBox(width: 12),
              _GlassChip(
                icon: _paused
                    ? LucideIcons.play
                    : LucideIcons.pause,
                label: _paused ? 'Play' : 'Pause',
                onTap: _togglePause,
                focusNode: _playFocus,
              ),
              const SizedBox(width: 12),
              _GlassChip(
                icon: LucideIcons.sparkles,
                label: 'Ask',
                onTap: _ask,
                focusNode: _askFocus,
              ),
              const Spacer(),
              Text(
                _counterLabel,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.85),
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  shadows: [Shadow(blurRadius: 8, color: Colors.black54)],
                ),
              ),
            ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _GlassChip extends StatefulWidget {
  const _GlassChip({
    required this.icon,
    required this.label,
    required this.onTap,
    this.focusNode,
  });
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final FocusNode? focusNode;

  @override
  State<_GlassChip> createState() => _GlassChipState();
}

class _GlassChipState extends State<_GlassChip> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    return FocusableActionDetector(
      focusNode: widget.focusNode,
      mouseCursor: SystemMouseCursors.click,
      onShowHoverHighlight: (h) => setState(() => _hover = h),
      onShowFocusHighlight: (h) => setState(() => _hover = h),
      actions: {
        ActivateIntent:
            CallbackAction<ActivateIntent>(onInvoke: (_) => widget.onTap()),
      },
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: _hover ? Colors.white : Colors.white.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(19),
            border: Border.all(color: Colors.white.withValues(alpha: 0.22)),
          ),
          child: Row(
            children: [
              Icon(widget.icon,
                  size: 16, color: _hover ? Colors.black : Colors.white),
              const SizedBox(width: 8),
              Text(widget.label,
                  style: TextStyle(
                      color: _hover ? Colors.black : Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    );
  }
}

/// A photo with an optional slow Ken Burns zoom/pan.
class _SlideImage extends StatefulWidget {
  const _SlideImage({
    super.key,
    required this.entry,
    required this.zoom,
    required this.kenBurns,
    required this.duration,
    required this.seed,
  });
  final MediaEntry entry;

  /// Zoom while paused (shared with the slideshow's key handling).
  final ZoomController zoom;
  final bool kenBurns;
  final Duration duration;
  final int seed;

  @override
  State<_SlideImage> createState() => _SlideImageState();
}

class _SlideImageState extends State<_SlideImage>
    with SingleTickerProviderStateMixin {
  File? _file;
  late final AnimationController _kb = AnimationController(
    vsync: this,
    duration: widget.duration,
  );

  @override
  void initState() {
    super.initState();
    _load();
    if (widget.kenBurns) _kb.forward();
  }

  Future<void> _load() async {
    // Same quality as the prebuffer so this hits the already-decoded cache
    // (no reload / loading flash when the slide appears).
    final f = await ThumbnailService.instance
        .fullImage(widget.entry, quality: _slideImageQuality);
    if (mounted) setState(() => _file = f);
  }

  @override
  void dispose() {
    _kb.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_file == null) {
      return const Center(child: CircularProgressIndicator());
    }
    // Plain fit (and any zoom while paused) is the shared zoomable view; Ken
    // Burns switches to it once the paused photo is zoomed.
    if (!widget.kenBurns) {
      return ZoomableImage(file: _file!, controller: widget.zoom);
    }
    return ListenableBuilder(
      listenable: widget.zoom,
      builder: (context, _) => widget.zoom.isZoomed
          ? ZoomableImage(file: _file!, controller: widget.zoom)
          : _kenBurns(),
    );
  }

  Widget _kenBurns() {
    final image = Image.file(_file!, fit: BoxFit.contain, gaplessPlayback: true);

    // Alternate pan direction by seed for variety.
    final dir = widget.seed.isEven ? 1.0 : -1.0;
    return AnimatedBuilder(
      animation: _kb,
      builder: (context, child) {
        final t = Curves.easeInOut.transform(_kb.value);
        final scale = 1.06 + 0.14 * t;
        final dx = dir * 18 * t;
        final dy = -10 * t;
        return Transform.translate(
          offset: Offset(dx, dy),
          child: Transform.scale(scale: scale, child: child),
        );
      },
      child: SizedBox.expand(child: FittedBox(fit: BoxFit.cover, child: image)),
    );
  }
}

class _SlideVideo extends StatefulWidget {
  const _SlideVideo({
    super.key,
    required this.entry,
    required this.onEnd,
    required this.muted,
    required this.paused,
    this.captionDate,
    this.captionPlace,
  });
  final MediaEntry entry;
  final VoidCallback onEnd;
  final bool muted;
  final bool paused;

  /// Drawn on the video by the backend, not as a Flutter overlay.
  final String? captionDate;
  final String? captionPlace;

  @override
  State<_SlideVideo> createState() => _SlideVideoState();
}

class _SlideVideoState extends State<_SlideVideo> {
  VideoBackend? _backend;
  StreamSubscription<void>? _completedSub;
  bool _ready = false;
  bool _ended = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final file = await ThumbnailService.instance.originFile(widget.entry);
    if (file == null) {
      widget.onEnd();
      return;
    }
    if (!mounted) return;
    final backend = VideoBackend(file.path, muted: widget.muted);
    _backend = backend;
    // Advance the slideshow when the clip finishes.
    _completedSub = backend.completedStream.listen((_) {
      if (!_ended) {
        _ended = true;
        // Release the decoder before the next slide (often another video)
        // needs it.
        unawaited(backend.stop());
        widget.onEnd();
      }
    });
    unawaited(backend.setCaption(
        date: widget.captionDate, place: widget.captionPlace));
    if (!widget.paused) backend.play();
    if (mounted) setState(() => _ready = true);
  }

  @override
  void didUpdateWidget(_SlideVideo oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The place resolves after the slide starts — pass it on to the video.
    unawaited(_backend?.setCaption(
        date: widget.captionDate, place: widget.captionPlace));
    // The slideshow's play/pause toggle flows in through `paused` — mirror it
    // onto the player so OK (or the on-screen chip) pauses/resumes video.
    if (oldWidget.paused != widget.paused && _backend != null) {
      if (widget.paused) {
        _backend!.pause();
      } else {
        _backend!.play();
      }
    }
  }

  @override
  void dispose() {
    _completedSub?.cancel();
    _backend?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final backend = _backend;
    if (!_ready || backend == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return backend.buildView();
  }
}
