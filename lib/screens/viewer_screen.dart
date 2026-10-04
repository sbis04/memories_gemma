import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../core/app_theme.dart';
import '../core/transitions.dart';
import '../services/location_service.dart';
import '../services/video/video_backend.dart';
import '../widgets/ask_panel.dart';
import '../widgets/media_caption.dart';
import '../widgets/zoomable_image.dart';
import '../models/media_entry.dart';
import '../services/settings_controller.dart';
// hide its custom Size so the Flutter Size (with .zero/.shortestSide) wins here.
import '../services/thumbnail_service.dart' hide Size;
import 'slideshow_screen.dart';

/// Commands the viewer routes to the active *photo* page. Carried on a sequenced
/// ValueNotifier so the active page reacts once per press (a signal, not a
/// GlobalKey — that previously caused next-photo to show the previous one).
/// Videos handle their own input via focusable on-screen controls.
enum _ViewerAction { activate, resetZoom }

/// Immersive fullscreen viewer. When a photo is at fit, Left/Right move between
/// items and OK steps zoom (125 → 150 → 175 → back to fit). While zoomed, the
/// arrows pan, OK keeps stepping, and Back returns to fit first. On a video, OK
/// plays/pauses. A slideshow can auto-advance.
class ViewerScreen extends StatefulWidget {
  const ViewerScreen({
    super.key,
    required this.media,
    required this.initialIndex,
    this.folderPath,
  });

  final List<MediaEntry> media;
  final int initialIndex;

  /// The folder these items belong to — passed through to the slideshow so it
  /// can be remembered for resuming. Null if unknown.
  final String? folderPath;

  @override
  State<ViewerScreen> createState() => _ViewerScreenState();
}

class _ViewerScreenState extends State<ViewerScreen> {
  late final PageController _page =
      PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;
  bool _controls = true;
  Timer? _hideTimer;

  // No key pressed for 10s: the caption fades out too (the top bar already
  // hides sooner), so nothing static sits on the TV — burn-in.
  bool _idle = false;
  Timer? _idleTimer;

  void _resetIdle() {
    if (_idle) setState(() => _idle = false);
    _idleTimer?.cancel();
    _idleTimer = Timer(const Duration(seconds: 10), () {
      if (mounted) setState(() => _idle = true);
    });
  }

  // Commands to the active page, sequenced so each press fires exactly once.
  final ValueNotifier<(int, _ViewerAction)> _command =
      ValueNotifier<(int, _ViewerAction)>((0, _ViewerAction.activate));
  int _cmdSeq = 0;

  // Whether the current photo is zoomed in — drives whether arrows pan vs.
  // navigate, and whether Back returns to fit vs. exits. Reported by the page.
  bool _zoomed = false;

  // Reverse-geocoded place name for the current photo (lower-left caption);
  // null while resolving or when the photo has no GPS.
  String? _placeName;

  void _send(_ViewerAction action) =>
      _command.value = (++_cmdSeq, action);

  // Zoom state per photo page (pages reset theirs when scrolled away).
  final Map<int, ZoomController> _zooms = {};
  ZoomController _zoomFor(int index) =>
      _zooms.putIfAbsent(index, ZoomController.new);

  // Focus on the image area (D-pad navigates photos); pressing Up moves focus
  // to the Slideshow button.
  final FocusNode _imageFocus = FocusNode(debugLabel: 'viewerImage');
  final FocusNode _slideshowFocus = FocusNode(debugLabel: 'slideshow');
  final FocusNode _askFocus = FocusNode(debugLabel: 'ask');

  @override
  void initState() {
    super.initState();
    _resetIdle();
    // Reveal controls whenever the Slideshow button gains focus (i.e. Up).
    _askFocus.addListener(() {
      if (_askFocus.hasFocus) _wake();
    });
    _slideshowFocus.addListener(() {
      if (_slideshowFocus.hasFocus) _wake();
    });
    _scheduleHide();
    _resolvePlace(_index);
  }

  /// Reverse-geocodes the item at [index] and shows it once resolved (ignoring
  /// stale results if the user has since moved to another item).
  Future<void> _resolvePlace(int index) async {
    setState(() => _placeName = null);
    final entry = widget.media[index];
    final place = await LocationService.instance.placeName(entry);
    if (mounted && _index == index) setState(() => _placeName = place);
  }


  @override
  void dispose() {
    _hideTimer?.cancel();
    _idleTimer?.cancel();
    _zoomHintTimer?.cancel();
    _command.dispose();
    _imageFocus.dispose();
    _slideshowFocus.dispose();
    _askFocus.dispose();
    _page.dispose();
    for (final z in _zooms.values) {
      z.dispose();
    }
    super.dispose();
  }

  void _onPageZoom(bool zoomed) {
    if (_zoomed == zoomed || !mounted) return;
    setState(() {
      _zoomed = zoomed;
      _zoomHint = zoomed;
    });
    _zoomHintTimer?.cancel();
    if (zoomed) {
      _zoomHintTimer = Timer(const Duration(milliseconds: 2500), () {
        if (mounted) setState(() => _zoomHint = false);
      });
    }
  }

  bool _zoomHint = false;
  Timer? _zoomHintTimer;

  MediaEntry get _current => widget.media[_index];

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(milliseconds: 3500), () {
      if (!mounted) return;
      setState(() => _controls = false);
      // Don't leave focus stranded on the now-hidden Slideshow button.
      if (_slideshowFocus.hasFocus || _askFocus.hasFocus) {
        _imageFocus.requestFocus();
      }
    });
  }

  void _wake() {
    if (!_controls) setState(() => _controls = true);
    _scheduleHide();
    _resetIdle();
  }

  void _go(int delta) {
    final next = _index + delta;
    if (next < 0 || next >= widget.media.length) return;
    _page.animateToPage(
      next,
      duration: AppTheme.pageTransition,
      curve: AppTheme.emphasized,
    );
    // Intentionally does NOT reveal the overlay — paging stays immersive.
  }

  static final _okKeys = {
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.numpadEnter,
    LogicalKeyboardKey.space,
    LogicalKeyboardKey.select,
  };
  bool _okDown = false;
  bool _okHeld = false;

  /// OK: a press (acted on release) steps zoom; holding it opens the top bar
  /// on Ask — reachable from anywhere, zoomed or not.
  KeyEventResult _onOk(KeyEvent event) {
    switch (event) {
      case KeyDownEvent():
        _okDown = true;
        _okHeld = false;
        _resetIdle();
      case KeyRepeatEvent():
        if (_okDown && !_okHeld) {
          _okHeld = true;
          _askFocus.requestFocus(); // listener reveals the controls
        }
      case KeyUpEvent():
        if (_okDown && !_okHeld) _send(_ViewerAction.activate);
        _okDown = false;
    }
    return KeyEventResult.handled;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (_okKeys.contains(event.logicalKey)) return _onOk(event);
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    _resetIdle();
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowLeft:
        // Zoomed photo: pan. Otherwise move to the previous item. (Videos
        // handle their own arrows via on-screen controls and never reach here.)
        _zoomed ? _zoomFor(_index).pan(const Offset(1, 0)) : _go(-1);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowRight:
        _zoomed ? _zoomFor(_index).pan(const Offset(-1, 0)) : _go(1);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp:
        // Zoomed: pan up; at the top edge, Up reaches the top bar (on Ask,
        // the useful action while zoomed). Listeners reveal the controls.
        if (!_zoomed) {
          _slideshowFocus.requestFocus();
        } else if (!_zoomFor(_index).pan(const Offset(0, 1))) {
          _askFocus.requestFocus();
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowDown:
        // Down asks Gemini (zoomed: pan down first, ask at the bottom edge).
        if (!_zoomed || !_zoomFor(_index).pan(const Offset(0, -1))) {
          unawaited(_ask());
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.mediaPlayPause:
        _send(_ViewerAction.activate);
        return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Ask Gemini about the current item — what's zoomed in on, if zoomed.
  Future<void> _ask() async {
    _hideTimer?.cancel();
    final entry = _current;
    await showAskPanel(context, entry,
        focus: entry.isImage ? _zooms[_index]?.visibleRegion : null);
    if (mounted) _scheduleHide();
  }

  Future<void> _startSlideshow() async {
    final stoppedAt = await Navigator.of(context).push<int>(FadeZoomPageRoute(
      child: SlideshowScreen(
        media: widget.media,
        startIndex: _index,
        folderPath: widget.folderPath,
      ),
    ));
    // The slideshow returns the item it stopped on — jump the viewer there so
    // the photo on screen matches where the slideshow left off.
    if (stoppedAt != null && mounted && stoppedAt != _index) {
      setState(() => _index = stoppedAt);
      if (_page.hasClients) _page.jumpToPage(stoppedAt);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // While zoomed, Back returns the photo to fit instead of leaving.
      canPop: !_zoomed,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _zoomed) {
          _send(_ViewerAction.resetZoom);
          setState(() => _zoomed = false);
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Focus(
          focusNode: _imageFocus,
          autofocus: true,
          onKeyEvent: _onKey,
          child: MouseRegion(
            onHover: (_) => _wake(),
            child: Stack(
              fit: StackFit.expand,
              children: [
                PageView.builder(
                  controller: _page,
                  itemCount: widget.media.length,
                  onPageChanged: (i) {
                    // A freshly-shown page is always at fit.
                    setState(() {
                      _index = i;
                      _zoomed = false;
                    });
                    // Photos are driven by the central key handler; videos own
                    // their focus (their on-screen controls).
                    if (!widget.media[i].isVideo) _imageFocus.requestFocus();
                    _resolvePlace(i);
                  },
                  itemBuilder: (context, i) {
                    final entry = widget.media[i];
                    final active = i == _index;
                    if (entry.isVideo) {
                      final caption = SettingsController.instance.showCaption;
                      return _VideoPage(
                        key: ValueKey(entry.path),
                        entry: entry,
                        active: active,
                        captionDate: caption
                            ? MediaCaption.formatDate(entry.modified)
                            : null,
                        captionPlace: caption && active ? _placeName : null,
                        onTap: _wake,
                        onPrev: () => _go(-1),
                        onNext: () => _go(1),
                      );
                    }
                    return _ImagePage(
                      key: ValueKey(entry.path),
                      entry: entry,
                      active: active,
                      command: _command,
                      zoom: _zoomFor(i),
                      onTap: _wake,
                      onZoomChanged: _onPageZoom,
                    );
                  },
                ),
                _buildControls(context),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildControls(BuildContext context) {
    // Videos draw their own focusable controls (play/pause + scrubber); this
    // overlay is only for photos.
    if (_current.isVideo) return const SizedBox.shrink();
    return IgnorePointer(
      ignoring: !_controls,
      child: AnimatedOpacity(
        opacity: _controls ? 1 : 0,
        duration: const Duration(milliseconds: 250),
        child: Stack(
          children: [
            // Top bar: filename / counter + Slideshow. (No close button — the
            // remote's Back already exits.)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Container(
                // No backdrop gradient over the photo — buttons have their own
                // pills and text a soft shadow.
                padding: const EdgeInsets.fromLTRB(28, 20, 28, 40),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _current.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                              shadows: [Shadow(blurRadius: 8, color: Colors.black54)],
                            ),
                          ),
                          Text(
                            '${_index + 1} of ${widget.media.length}'
                            '${_current.isVideo ? "   ·   Video" : ""}',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.7),
                              fontSize: 13,
                              shadows: [Shadow(blurRadius: 8, color: Colors.black54)],
                            ),
                          ),
                        ],
                      ),
                    ),
                    _TopPill(
                      icon: LucideIcons.sparkles,
                      label: 'Ask',
                      focusNode: _askFocus,
                      onActivate: _ask,
                      onDown: () => _imageFocus.requestFocus(),
                      onRight: () => _slideshowFocus.requestFocus(),
                    ),
                    const SizedBox(width: 10),
                    _TopPill(
                      icon: LucideIcons.play,
                      label: 'Slideshow',
                      focusNode: _slideshowFocus,
                      onActivate: _startSlideshow,
                      onDown: () => _imageFocus.requestFocus(),
                      onLeft: () => _askFocus.requestFocus(),
                    ),
                  ],
                ),
              ),
            ),
            // Bare chevron hints (fill on hover; D-pad uses Left/Right directly).
            Positioned(
              left: 18,
              top: 0,
              bottom: 0,
              child: Center(
                child: _ChevronHint(
                  icon: LucideIcons.chevronLeft,
                  enabled: _index > 0,
                  onTap: () => _go(-1),
                ),
              ),
            ),
            Positioned(
              right: 18,
              top: 0,
              bottom: 0,
              child: Center(
                child: _ChevronHint(
                  icon: LucideIcons.chevronRight,
                  enabled: _index < widget.media.length - 1,
                  onTap: () => _go(1),
                ),
              ),
            ),
            // How to get around a zoomed photo (shown briefly on zooming in).
            Positioned(
              left: 0,
              right: 0,
              bottom: 28,
              child: Center(child: ZoomHint(visible: _zoomHint)),
            ),
            // Lower-left caption: place (if any) above the date. Android videos
            // draw it natively instead (_VideoPage) — a Flutter layer on top of
            // the native video surface makes the TV GPU-composite every frame
            // (dropped frames on 4K/60fps).
            if (SettingsController.instance.showCaption &&
                !(_current.isVideo && Platform.isAndroid))
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
          ],
        ),
      ),
    );
  }
}

/// A bare chevron that fills into a circle only on hover (mouse). Not in the
/// D-pad path — photo paging is done with Left/Right directly.
class _ChevronHint extends StatefulWidget {
  const _ChevronHint(
      {required this.icon, required this.enabled, required this.onTap});
  final IconData icon;
  final bool enabled;
  final VoidCallback onTap;

  @override
  State<_ChevronHint> createState() => _ChevronHintState();
}

class _ChevronHintState extends State<_ChevronHint> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) {
      return Opacity(
        opacity: 0.25,
        child: Icon(widget.icon, color: Colors.white, size: 26),
      );
    }
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: AppTheme.focusAnim,
          width: 44,
          height: 44,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: _hover ? Colors.white : Colors.transparent,
            shape: BoxShape.circle,
          ),
          child: Icon(widget.icon,
              color: _hover ? Colors.black : Colors.white, size: 26),
        ),
      ),
    );
  }
}

/// Focusable Slideshow button: reachable by pressing Up from the photo, OK to
/// start, Down to return focus to the photo. Bare label when idle, filled when
/// focused or hovered.
/// A top-bar pill (Ask, Slideshow). Down returns to the photo; Left/Right
/// move between the pills.
class _TopPill extends StatefulWidget {
  const _TopPill({
    required this.icon,
    required this.label,
    required this.focusNode,
    required this.onActivate,
    required this.onDown,
    this.onLeft,
    this.onRight,
  });
  final IconData icon;
  final String label;
  final FocusNode focusNode;
  final VoidCallback onActivate;
  final VoidCallback onDown;
  final VoidCallback? onLeft;
  final VoidCallback? onRight;

  @override
  State<_TopPill> createState() => _TopPillState();
}

class _TopPillState extends State<_TopPill> {
  bool _hover = false;

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    switch (e.logicalKey) {
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.numpadEnter:
      case LogicalKeyboardKey.space:
      case LogicalKeyboardKey.select:
        widget.onActivate();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowDown:
        widget.onDown();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowLeft:
        widget.onLeft?.call();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowRight:
        widget.onRight?.call();
        return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: widget.focusNode,
      onKeyEvent: _onKey,
      child: AnimatedBuilder(
        animation: widget.focusNode,
        builder: (context, _) {
          final active = widget.focusNode.hasFocus || _hover;
          final fg = active ? Colors.black : Colors.white;
          return MouseRegion(
            cursor: SystemMouseCursors.click,
            onEnter: (_) => setState(() => _hover = true),
            onExit: (_) => setState(() => _hover = false),
            child: GestureDetector(
              onTap: widget.onActivate,
              child: AnimatedContainer(
                duration: AppTheme.focusAnim,
                height: 38,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  color: active ? Colors.white : Colors.transparent,
                  borderRadius: BorderRadius.circular(19),
                  border: Border.all(
                      color: Colors.white.withValues(alpha: active ? 1 : 0.4)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(widget.icon, size: 16, color: fg),
                    const SizedBox(width: 8),
                    Text(widget.label,
                        style: TextStyle(
                            color: fg,
                            fontSize: 14,
                            fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// A photo that steps through discrete zoom levels and pans with the D-pad.
class _ImagePage extends StatefulWidget {
  const _ImagePage({
    super.key,
    required this.entry,
    required this.active,
    required this.command,
    required this.zoom,
    required this.onTap,
    this.onZoomChanged,
  });
  final MediaEntry entry;
  final bool active;
  final ValueListenable<(int, _ViewerAction)> command;

  /// Owned by the viewer (so it can tell Gemini what's zoomed in on).
  final ZoomController zoom;
  final VoidCallback onTap;
  final ValueChanged<bool>? onZoomChanged;

  @override
  State<_ImagePage> createState() => _ImagePageState();
}

class _ImagePageState extends State<_ImagePage> {
  File? _file;
  bool _failed = false;

  ZoomController get _zoom => widget.zoom;

  @override
  void initState() {
    super.initState();
    _load();
    widget.command.addListener(_onCommand);
    _zoom.addListener(_onZoom);
  }

  @override
  void didUpdateWidget(_ImagePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // If this page scrolls off-screen, drop any zoom so it's back at fit when
    // revisited (and neighbours in the PageView are never left zoomed).
    if (oldWidget.active && !widget.active) _zoom.reset();
  }

  void _onZoom() => widget.onZoomChanged?.call(_zoom.isZoomed);

  void _onCommand() {
    if (!widget.active) return;
    switch (widget.command.value.$2) {
      case _ViewerAction.activate:
        _zoom.cycle();
      case _ViewerAction.resetZoom:
        _zoom.reset();
    }
  }

  @override
  void dispose() {
    widget.command.removeListener(_onCommand);
    _zoom.removeListener(_onZoom);
    super.dispose();
  }

  Future<void> _load() async {
    // A screen-sized image. We deliberately do NOT decode the full original:
    // phone photos are often 12–48MP and decoding one into a Flutter bitmap
    // (~50–190MB) blows the TV's memory. A ~2560px image is sharp on a 4K TV
    // and zooms fine.
    final f = await ThumbnailService.instance.fullImage(widget.entry);
    if (!mounted) return;
    setState(() {
      _file = f;
      _failed = f == null;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) {
      return const Center(
        child: Icon(LucideIcons.imageOff, color: Colors.white54, size: 48),
      );
    }
    if (_file == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return GestureDetector(
      onTap: widget.onTap,
      child: ZoomableImage(file: _file!, controller: _zoom),
    );
  }
}

/// A video page backed by a [VideoBackend] — native ExoPlayer/SurfaceView on
/// Android (true HDR/Dolby Vision + smooth high-fps), media_kit elsewhere.
///
/// Controls are focusable: a centre play/pause button (Left/Right move between
/// items, OK toggles) and a bottom scrubber (focused = blue; Left/Right scrub
/// and never navigate). Up/Down move focus between them. The overlay auto-hides
/// after 3s once playing; any key brings it back, and it stays up while paused.
/// A wakelock is held only while actually playing.
class _VideoPage extends StatefulWidget {
  const _VideoPage({
    super.key,
    required this.entry,
    required this.active,
    required this.onTap,
    required this.onPrev,
    required this.onNext,
    this.captionDate,
    this.captionPlace,
  });

  final MediaEntry entry;
  final bool active;

  /// Drawn on the video by the backend, not as a Flutter overlay.
  final String? captionDate;
  final String? captionPlace;
  final VoidCallback onTap;
  final VoidCallback onPrev;
  final VoidCallback onNext;

  @override
  State<_VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<_VideoPage> {
  static const Duration _scrubStep = Duration(seconds: 10);

  VideoBackend? _backend;
  final List<StreamSubscription<dynamic>> _subs = [];
  // Focus targets: _idleFocus holds focus while the overlay is hidden (any key
  // just reveals it); the play/pause button and scrubber take focus when shown.
  final FocusNode _idleFocus = FocusNode(debugLabel: 'videoIdle');
  final FocusNode _playFocus = FocusNode(debugLabel: 'videoPlayPause');
  final FocusNode _scrubFocus = FocusNode(debugLabel: 'videoScrubber');
  bool _ready = false;
  bool _playing = false;
  bool _ended = false;
  bool _controls = true;
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final file = await ThumbnailService.instance.originFile(widget.entry);
    if (file == null || !mounted) return;
    final backend =
        VideoBackend(file.path, muted: SettingsController.instance.muteVideo);
    _backend = backend;
    _subs.add(backend.playingStream.listen((playing) {
      if (!mounted) return;
      setState(() => _playing = playing);
      // Keep the screen awake only while actually playing; release on pause/end.
      unawaited(WakelockPlus.toggle(enable: playing));
    }));
    _subs.add(backend.completedStream.listen((_) {
      if (!mounted) return;
      _ended = true;
      _showControls(); // surface the controls at the end (they stay while idle)
    }));
    unawaited(backend.setCaption(
        date: widget.captionDate, place: widget.captionPlace));
    setState(() => _ready = true);
    _applyActive();
  }

  @override
  void didUpdateWidget(_VideoPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    unawaited(_backend?.setCaption(
        date: widget.captionDate, place: widget.captionPlace));
    if (widget.active != oldWidget.active) _applyActive();
  }

  void _applyActive() {
    final backend = _backend;
    if (backend == null) return;
    if (widget.active) {
      if (SettingsController.instance.autoplayVideos) backend.play();
      _showControls();
    } else {
      _hideTimer?.cancel();
      // Swiped away: free the decoder (play() re-prepares if we come back).
      backend.stop();
      backend.seek(Duration.zero);
      _ended = false;
      unawaited(WakelockPlus.disable());
      if (mounted) setState(() => _controls = false);
    }
  }

  /// Reveals the controls, focuses the play/pause button (if neither control is
  /// focused yet) and (re)arms the inactivity hide — which only fires while
  /// playing, so the controls stay up when paused/ended.
  void _showControls() {
    _hideTimer?.cancel();
    if (mounted && !_controls) setState(() => _controls = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.active || !_controls) return;
      if (!_playFocus.hasFocus && !_scrubFocus.hasFocus) {
        _playFocus.requestFocus();
      }
    });
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted || !_playing) return; // keep controls up while paused/ended
      setState(() => _controls = false);
      _idleFocus.requestFocus();
    });
  }

  void _togglePlay() {
    final backend = _backend;
    if (backend == null) return;
    if (_playing) {
      backend.pause();
    } else {
      if (_ended) {
        backend.seek(Duration.zero);
        _ended = false;
      }
      backend.play();
    }
    _showControls();
  }

  void _scrub(Duration delta) {
    final backend = _backend;
    if (backend == null) return;
    final dur = backend.duration;
    var pos = backend.position + delta;
    if (pos < Duration.zero) pos = Duration.zero;
    if (pos > dur) pos = dur;
    backend.seek(pos);
    _showControls();
  }

  // ---- key handling, per focus target ----

  KeyEventResult _onIdleKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    switch (e.logicalKey) {
      case LogicalKeyboardKey.arrowLeft:
      case LogicalKeyboardKey.arrowRight:
      case LogicalKeyboardKey.arrowUp:
      case LogicalKeyboardKey.arrowDown:
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.numpadEnter:
      case LogicalKeyboardKey.space:
      case LogicalKeyboardKey.select:
      case LogicalKeyboardKey.mediaPlayPause:
        _showControls(); // a press while hidden just reveals the controls
        return KeyEventResult.handled;
      default:
        return KeyEventResult.ignored;
    }
  }

  KeyEventResult _onPlayKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    switch (e.logicalKey) {
      case LogicalKeyboardKey.arrowLeft:
        _showControls();
        widget.onPrev();
      case LogicalKeyboardKey.arrowRight:
        _showControls();
        widget.onNext();
      case LogicalKeyboardKey.arrowDown:
        _showControls();
        _scrubFocus.requestFocus();
      case LogicalKeyboardKey.arrowUp:
        _showControls(); // reserved — stay on the button
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.numpadEnter:
      case LogicalKeyboardKey.space:
      case LogicalKeyboardKey.select:
      case LogicalKeyboardKey.mediaPlayPause:
        _togglePlay();
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  KeyEventResult _onScrubKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    switch (e.logicalKey) {
      case LogicalKeyboardKey.arrowLeft:
        _scrub(-_scrubStep);
      case LogicalKeyboardKey.arrowRight:
        _scrub(_scrubStep);
      case LogicalKeyboardKey.arrowUp:
        _showControls();
        _playFocus.requestFocus();
      case LogicalKeyboardKey.arrowDown:
        _showControls(); // stay on the scrubber
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.numpadEnter:
      case LogicalKeyboardKey.space:
      case LogicalKeyboardKey.select:
      case LogicalKeyboardKey.mediaPlayPause:
        _togglePlay();
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    _idleFocus.dispose();
    _playFocus.dispose();
    _scrubFocus.dispose();
    unawaited(WakelockPlus.disable());
    _backend?.dispose();
    super.dispose();
  }

  static String _fmt(Duration d) {
    final s = d.inSeconds;
    final m = s ~/ 60;
    final sec = (s % 60).toString().padLeft(2, '0');
    return '$m:$sec';
  }

  @override
  Widget build(BuildContext context) {
    final backend = _backend;
    if (!_ready || backend == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return Focus(
      focusNode: _idleFocus,
      onKeyEvent: _onIdleKey,
      child: GestureDetector(
        onTap: () {
          widget.onTap();
          _showControls();
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            backend.buildView(),
            IgnorePointer(
              ignoring: !_controls,
              child: AnimatedOpacity(
                opacity: _controls ? 1 : 0,
                duration: const Duration(milliseconds: 250),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Center(
                      child: _PlayPauseButton(
                        focusNode: _playFocus,
                        onKey: _onPlayKey,
                        playing: _playing,
                        onTap: _togglePlay,
                      ),
                    ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: _VideoScrubber(
                        focusNode: _scrubFocus,
                        onKey: _onScrubKey,
                        backend: backend,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Focusable centre play/pause button. Fills white (with a glow) when focused.
class _PlayPauseButton extends StatelessWidget {
  const _PlayPauseButton({
    required this.focusNode,
    required this.onKey,
    required this.playing,
    required this.onTap,
  });

  final FocusNode focusNode;
  final FocusOnKeyEventCallback onKey;
  final bool playing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: focusNode,
      onKeyEvent: onKey,
      child: AnimatedBuilder(
        animation: focusNode,
        builder: (context, _) {
          final focused = focusNode.hasFocus;
          return GestureDetector(
            onTap: onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: 74,
              height: 74,
              decoration: BoxDecoration(
                color: focused
                    ? Colors.white
                    : Colors.black.withValues(alpha: 0.45),
                shape: BoxShape.circle,
                border: Border.all(
                    color: Colors.white.withValues(alpha: focused ? 1 : 0.8),
                    width: 2),
                boxShadow: focused
                    ? [
                        BoxShadow(
                            color: Colors.white.withValues(alpha: 0.35),
                            blurRadius: 18)
                      ]
                    : null,
              ),
              child: Icon(
                playing ? LucideIcons.pause : LucideIcons.play,
                color: focused ? Colors.black : Colors.white,
                size: 36,
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Focusable bottom scrubber. Turns blue and thickens when focused.
class _VideoScrubber extends StatelessWidget {
  const _VideoScrubber({
    required this.focusNode,
    required this.onKey,
    required this.backend,
  });

  final FocusNode focusNode;
  final FocusOnKeyEventCallback onKey;
  final VideoBackend backend;

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: focusNode,
      onKeyEvent: onKey,
      child: AnimatedBuilder(
        animation: focusNode,
        builder: (context, _) {
          final focused = focusNode.hasFocus;
          const blue = Color(0xFF3B82F6);
          final accent = focused ? blue : Colors.white;
          return Container(
            padding: const EdgeInsets.fromLTRB(28, 28, 28, 24),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [Color(0xCC000000), Colors.transparent],
              ),
            ),
            child: StreamBuilder<Duration>(
              stream: backend.positionStream,
              builder: (context, snapshot) {
                final pos = snapshot.data ?? backend.position;
                final dur = backend.duration;
                final frac = dur.inMilliseconds > 0
                    ? (pos.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0)
                    : 0.0;
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        value: frac,
                        minHeight: focused ? 6 : 3,
                        backgroundColor: Colors.white24,
                        valueColor: AlwaysStoppedAnimation<Color>(accent),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Text(_VideoPageState._fmt(pos),
                            style: TextStyle(
                                color: focused ? blue : Colors.white,
                                fontSize: 12,
                                fontWeight: focused
                                    ? FontWeight.w700
                                    : FontWeight.w400)),
                        const Spacer(),
                        Text(_VideoPageState._fmt(dur),
                            style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.7),
                                fontSize: 12)),
                      ],
                    ),
                  ],
                );
              },
            ),
          );
        },
      ),
    );
  }
}
