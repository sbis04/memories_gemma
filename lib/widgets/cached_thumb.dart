import 'dart:io';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../core/app_theme.dart';
import '../models/media_entry.dart';
import '../services/thumbnail_service.dart' show ThumbCancel, ThumbnailService;
import 'media_caption.dart';
import 'visibility_gate.dart';

/// Asynchronously loads (and lazily generates) a thumbnail for a media entry,
/// fading it in over a soft placeholder. Shows a play badge for videos.
class CachedThumb extends StatefulWidget {
  const CachedThumb({
    super.key,
    required this.entry,
    this.maxDim = 480,
    this.quality = 95,
    this.fit = BoxFit.cover,
    this.showVideoBadge = true,
    this.showInfo = false,
  });

  final MediaEntry entry;
  final int maxDim;

  /// JPEG quality (1–100) for the generated thumbnail. The gallery grid uses a
  /// lower value so tiles decode and load faster; the full-screen viewer uses a
  /// separate full-quality path.
  final int quality;
  final BoxFit fit;
  final bool showVideoBadge;

  /// Show the file name and date on the placeholder until the thumbnail
  /// arrives, so a grid you're racing through still says what each tile is.
  final bool showInfo;

  @override
  State<CachedThumb> createState() => _CachedThumbState();
}

class _CachedThumbState extends State<CachedThumb> with VisibilityGate {
  File? _file;
  bool _failed = false;
  ThumbCancel? _cancel;
  Size _screen = Size.zero;

  /// Loads only while the screen is showing: a covered screen drops its
  /// queued/in-flight thumbnails and picks them up again on return.
  @override
  void onVisibilityChanged(bool visible) {
    if (visible) {
      if (_file == null && !_failed && _cancel == null) _load();
    } else {
      _cancel?.cancel();
      _cancel = null;
    }
  }

  @override
  void didUpdateWidget(CachedThumb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.entry.path != widget.entry.path) {
      _file = null;
      _failed = false;
      _load();
    } else if (oldWidget.maxDim != widget.maxDim ||
        oldWidget.quality != widget.quality) {
      // Resolution/quality changed (e.g. the user zoomed) — refine in place,
      // keeping the current image visible (gapless) so there's no flash.
      _load();
    }
  }

  @override
  void dispose() {
    // Scrolled away: drop the request even if it's already decoding.
    _cancel?.cancel();
    super.dispose();
  }

  /// Distance from the middle of the screen — where the selected tile sits
  /// while scrolling — so the queue loads around the selection first.
  double _priority() {
    if (!mounted || !isVisible) return double.infinity;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) {
      return double.infinity;
    }
    final c = box.localToGlobal(box.size.center(Offset.zero));
    return (c.dy - _screen.height / 2).abs() +
        (c.dx - _screen.width / 2).abs() * 0.25;
  }

  Future<void> _load() async {
    _cancel?.cancel();
    final cancel = _cancel = ThumbCancel();
    final f = await ThumbnailService.instance.thumbnail(
      widget.entry,
      maxDim: widget.maxDim,
      quality: widget.quality,
      // If this tile scrolls off-screen before its turn in the queue, skip it
      // so the now-visible tiles load first.
      wanted: () => mounted && isVisible,
      priority: _priority,
      cancel: cancel,
    );
    if (identical(_cancel, cancel)) _cancel = null;
    if (!mounted || cancel.cancelled) return;
    setState(() {
      _file = f;
      _failed = f == null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    _screen = MediaQuery.sizeOf(context);
    return Stack(
      fit: StackFit.expand,
      children: [
        // Placeholder.
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [c.surface, c.bgBottom],
            ),
          ),
          child: _failed
              ? Center(
                  child: Icon(
                    widget.entry.isVideo
                        ? LucideIcons.film
                        : LucideIcons.imageOff,
                    color: c.textFaint,
                    size: 28,
                  ),
                )
              : null,
        ),
        if (widget.showInfo && _file == null) _info(c),
        // Image.
        AnimatedOpacity(
          opacity: _file != null ? 1 : 0,
          duration: const Duration(milliseconds: 420),
          curve: Curves.easeOut,
          child: _file == null
              ? const SizedBox.shrink()
              : Image.file(
                  _file!,
                  fit: widget.fit,
                  gaplessPlayback: true,
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                ),
        ),
        if (widget.showVideoBadge && widget.entry.isVideo)
          const Positioned.fill(child: _VideoBadge()),
      ],
    );
  }
}

extension on _CachedThumbState {
  /// Name + date, bottom-left, on tiles tall enough to fit them.
  Widget _info(GalleryColors c) {
    return LayoutBuilder(builder: (context, box) {
      if (box.maxHeight < 64 || box.maxWidth < 80) return const SizedBox();
      final date = widget.entry.modified;
      return Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.end,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.entry.displayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: c.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (date.millisecondsSinceEpoch > 0)
              Text(
                MediaCaption.formatShortDateTime(date),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: c.textFaint, fontSize: 11),
              ),
          ],
        ),
      );
    });
  }
}

class _VideoBadge extends StatelessWidget {
  const _VideoBadge();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.42),
          shape: BoxShape.circle,
          border:
              Border.all(color: Colors.white.withValues(alpha: 0.85), width: 1.2),
        ),
        child: const Icon(LucideIcons.play, color: Colors.white, size: 16),
      ),
    );
  }
}
