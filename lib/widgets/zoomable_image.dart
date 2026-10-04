import 'dart:io';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../core/app_theme.dart';

/// Stepped zoom + D-pad pan state for a [ZoomableImage]. OK steps through
/// [levels] (back to fit after the last); arrows pan while zoomed.
class ZoomController extends ChangeNotifier {
  static const List<double> levels = [1.0, 1.25, 1.5, 1.75, 2.0];

  int _level = 0;
  Offset _offset = Offset.zero; // pan, in viewport px
  Size _viewport = Size.zero;
  Size? _imageSize;

  double get scale => levels[_level];
  Offset get offset => _offset;
  bool get isZoomed => _level != 0;

  void cycle() {
    _level = (_level + 1) % levels.length;
    if (_level == 0) {
      _offset = Offset.zero;
    } else {
      _clamp();
    }
    notifyListeners();
  }

  void reset() {
    if (_level == 0) return;
    _level = 0;
    _offset = Offset.zero;
    notifyListeners();
  }

  /// Pans by a fifth of the screen; [dir] is the direction the image moves.
  /// Returns false when already at that edge (nothing moved) — screens use
  /// that to let the key do something else, e.g. reach the top bar.
  bool pan(Offset dir) {
    if (!isZoomed) return false;
    final base = _viewport.shortestSide == 0 ? 320.0 : _viewport.shortestSide;
    final before = _offset;
    _offset += dir * (base * 0.2);
    _clamp();
    if (_offset == before) return false;
    notifyListeners();
    return true;
  }

  /// Keeps the scaled image from panning past its edges into empty space.
  void _clamp() {
    final maxX = (scale - 1) * _viewport.width / 2;
    final maxY = (scale - 1) * _viewport.height / 2;
    _offset = Offset(
      _offset.dx.clamp(-maxX, maxX),
      _offset.dy.clamp(-maxY, maxY),
    );
  }

  static const _full = Rect.fromLTRB(0, 0, 1, 1);

  /// The part of the image currently on screen, in normalized image
  /// coordinates (0–1); the whole image when not zoomed. Used to show Gemma
  /// what the viewer zoomed in on.
  Rect get visibleRegion {
    final img = _imageSize;
    final vp = _viewport;
    if (!isZoomed || img == null || vp.isEmpty) return _full;
    // Where the image sits at fit (contain, centred)...
    final fitted = applyBoxFit(BoxFit.contain, img, vp).destination;
    final imageRect = Alignment.center.inscribe(fitted, Offset.zero & vp);
    // ...and which of it the zoomed view shows: screen q = c + offset +
    // scale·(p − c), so p = (q − c − offset) / scale + c.
    final c = vp.center(Offset.zero);
    Offset back(Offset q) => (q - c - _offset) / scale + c;
    final visible = Rect.fromPoints(
      back(Offset.zero),
      back(Offset(vp.width, vp.height)),
    ).intersect(imageRect);
    if (visible.isEmpty) return _full;
    return Rect.fromLTRB(
      (visible.left - imageRect.left) / imageRect.width,
      (visible.top - imageRect.top) / imageRect.height,
      (visible.right - imageRect.left) / imageRect.width,
      (visible.bottom - imageRect.top) / imageRect.height,
    );
  }
}

/// A photo fitted to the screen that zooms/pans per its [ZoomController],
/// animating between steps.
class ZoomableImage extends StatefulWidget {
  const ZoomableImage({super.key, required this.file, required this.controller});

  final File file;
  final ZoomController controller;

  @override
  State<ZoomableImage> createState() => _ZoomableImageState();
}

class _ZoomableImageState extends State<ZoomableImage> {
  ImageStream? _stream;
  late final ImageStreamListener _listener =
      ImageStreamListener((info, _) {
    widget.controller._imageSize =
        Size(info.image.width.toDouble(), info.image.height.toDouble());
  });

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(ZoomableImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.file.path != widget.file.path) _resolve();
  }

  /// Learns the image's pixel size (needed for [ZoomController.visibleRegion]).
  void _resolve() {
    final stream =
        FileImage(widget.file).resolve(createLocalImageConfiguration(context));
    if (stream.key == _stream?.key) return;
    _stream?.removeListener(_listener);
    _stream = stream..addListener(_listener);
  }

  @override
  void dispose() {
    _stream?.removeListener(_listener);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        widget.controller._viewport =
            Size(constraints.maxWidth, constraints.maxHeight);
        return ClipRect(
          child: ListenableBuilder(
            listenable: widget.controller,
            builder: (context, child) {
              final z = widget.controller;
              // Scale about centre, then translate by the pan offset (T·S).
              final target = Matrix4.identity()
                ..setEntry(0, 0, z.scale)
                ..setEntry(1, 1, z.scale)
                ..setEntry(0, 3, z.offset.dx)
                ..setEntry(1, 3, z.offset.dy);
              return TweenAnimationBuilder<Matrix4>(
                tween: Matrix4Tween(end: target),
                duration: AppTheme.focusAnim,
                curve: AppTheme.emphasized,
                builder: (context, matrix, child) => Transform(
                  alignment: Alignment.center,
                  transform: matrix,
                  child: child,
                ),
                child: child,
              );
            },
            child: Center(
              child: Image.file(
                widget.file,
                fit: BoxFit.contain,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => const Icon(LucideIcons.imageOff,
                    color: Colors.white54, size: 48),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// A brief bottom-centre hint shown on zooming in, so the remote controls for
/// a zoomed photo are discoverable.
class ZoomHint extends StatelessWidget {
  const ZoomHint({super.key, required this.visible});
  final bool visible;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: const Duration(milliseconds: 300),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(20),
          ),
          child: const Text(
            'Arrows pan  ·  Hold OK for menu  ·  Back resets zoom',
            style: TextStyle(color: Colors.white, fontSize: 14),
          ),
        ),
      ),
    );
  }
}
