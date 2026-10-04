import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;

import '../core/app_theme.dart';
import '../models/media_entry.dart';
import '../services/thumbnail_service.dart';
import 'cached_thumb.dart';
import 'focusable.dart';

/// A Flickr / Google-Photos style *justified* gallery: every row is the same
/// height with items sized by their true aspect ratio, and each row is
/// stretched to fill the width. This makes portrait and landscape media sit
/// together cleanly — far nicer for mixed orientations than a masonry grid.
///
/// Dimensions are resolved progressively; rows appear top-to-bottom as ratios
/// load, so nothing already on screen reflows underneath the viewer.
class JustifiedGallery extends StatefulWidget {
  const JustifiedGallery({
    super.key,
    required this.media,
    required this.rowHeight,
    required this.onOpen,
    this.showTitles = false,
    this.spacing = 5,
    this.scrollController,
    this.autofocusFirst = false,
    this.padding = EdgeInsets.zero,
    this.onFirstTileFocusChange,
    this.header,
  });

  final List<MediaEntry> media;
  final double rowHeight;
  final void Function(int index) onOpen;
  final bool showTitles;
  final double spacing;
  final ScrollController? scrollController;
  final bool autofocusFirst;
  final EdgeInsets padding;
  final ValueChanged<bool>? onFirstTileFocusChange;

  /// Optional widget rendered above the media rows in the same scroll view
  /// (used to place folder cards above a folder's media).
  final Widget? header;

  @override
  State<JustifiedGallery> createState() => _JustifiedGalleryState();
}

class _JustifiedGalleryState extends State<JustifiedGallery> {
  final Map<String, double> _aspect = {};
  int _readyCount = 0;
  double _lastWidth = 0;

  /// Grid thumbnails are kept deliberately small (and low quality) so a folder
  /// of thousands loads quickly while scrolling — the dominant cost on Android
  /// is decoding each source image, which scales with the requested size, so a
  /// smaller target is the biggest speed-up. The full-quality image is only
  /// generated when an item is opened in the viewer. Sized from the row height
  /// (higher zoom → sharper) and bucketed to one value per gallery so the
  /// on-disk cache is reused well.
  int get _thumbMaxDim => (widget.rowHeight * 1.4).round().clamp(180, 480);
  static const int _thumbQuality = 50;

  @override
  void initState() {
    super.initState();
    _resolveDimensions();
    // Warm the cache for the whole folder in the background.
    ThumbnailService.instance.prefetch(widget.media);
  }

  @override
  void dispose() {
    ThumbnailService.instance.cancelPendingSizes();
    super.dispose();
  }

  @override
  void didUpdateWidget(JustifiedGallery oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.media, widget.media)) {
      // The media list changed — typically because Android's MediaStore
      // finished indexing more of a USB drive and new items streamed in.
      // Keep the aspect ratios we've already resolved (they're keyed by path,
      // which is stable) and only resolve dimensions for entries we haven't
      // seen yet. Recompute the ready prefix synchronously so the items
      // already on screen stay rendered instead of clearing and flashing.
      final knownPaths = widget.media.map((e) => e.path).toSet();
      _aspect.removeWhere((path, _) => !knownPaths.contains(path));
      _recomputeReady();
      _resolveDimensions();
      ThumbnailService.instance.prefetch(widget.media);
    }
  }

  void _resolveDimensions() {
    for (final entry in widget.media) {
      // Skip entries whose aspect we already know — avoids redundant work and,
      // more importantly, keeps the existing layout stable across refreshes.
      if (_aspect.containsKey(entry.path)) continue;
      ThumbnailService.instance.dimensions(entry).then((size) {
        if (!mounted) return;
        final a = size == null ? 1.0 : size.aspect.clamp(0.45, 2.6);
        _aspect[entry.path] = a.toDouble();
        _advanceReady();
      });
    }
  }

  /// Grows the contiguous prefix of items whose aspect ratios are known.
  void _advanceReady() {
    var i = _readyCount;
    while (i < widget.media.length && _aspect.containsKey(widget.media[i].path)) {
      i++;
    }
    if (i != _readyCount) {
      setState(() => _readyCount = i);
    }
  }

  /// Recomputes the contiguous ready prefix from scratch, without a setState
  /// (callers are already inside a build/update cycle). Used when the media
  /// list is swapped so the prefix reflects which of the new items already
  /// have a cached aspect ratio.
  void _recomputeReady() {
    var i = 0;
    while (i < widget.media.length && _aspect.containsKey(widget.media[i].path)) {
      i++;
    }
    _readyCount = i;
  }

  /// Lays out *every* item straight away so the whole folder is scrollable
  /// at once; items whose real shape isn't known yet use a typical one (4:3
  /// photo, 16:9 video) and their rows settle as sizes arrive — in display
  /// order, so usually before they're scrolled to.
  List<_GRow> _pack(double width) {
    final rows = <_GRow>[];
    final target = widget.rowHeight;
    var cur = <_GItem>[];
    var sumAspect = 0.0;
    for (var i = 0; i < widget.media.length; i++) {
      final entry = widget.media[i];
      final aspect =
          _aspect[entry.path] ?? (entry.isVideo ? 16 / 9 : 4 / 3);
      cur.add(_GItem(index: i, entry: entry, aspect: aspect));
      sumAspect += aspect;
      final rowW = sumAspect * target + widget.spacing * (cur.length - 1);
      if (rowW >= width) {
        final h = (width - widget.spacing * (cur.length - 1)) / sumAspect;
        rows.add(_GRow(items: cur, height: h));
        cur = [];
        sumAspect = 0;
      }
    }
    if (cur.isNotEmpty) {
      rows.add(_GRow(items: cur, height: target));
    }
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth - widget.padding.horizontal;
        _lastWidth = width;
        final rows = _pack(width);
        final headerCount = widget.header != null ? 1 : 0;

        return ListView.builder(
          controller: widget.scrollController,
          padding: widget.padding,
          // Build a little beyond the viewport so the rows just above/below are
          // already loading — scrolling a short way never lands on blanks.
          scrollCacheExtent: ScrollCacheExtent.pixels(600),
          itemCount: headerCount + rows.length,
          itemBuilder: (context, rawIndex) {
            if (headerCount == 1 && rawIndex == 0) return widget.header!;
            final rowIndex = rawIndex - headerCount;
            final row = rows[rowIndex];
            return Padding(
              padding: EdgeInsets.only(bottom: widget.spacing),
              child: SizedBox(
                height: row.height,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var j = 0; j < row.items.length; j++) ...[
                      if (j > 0) SizedBox(width: widget.spacing),
                      _MediaTile(
                        key: ValueKey(row.items[j].entry.path),
                        entry: row.items[j].entry,
                        width: row.items[j].aspect * row.height,
                        height: row.height,
                        maxDim: _thumbMaxDim,
                        quality: _thumbQuality,
                        showTitle: widget.showTitles,
                        autofocus:
                            widget.autofocusFirst && row.items[j].index == 0,
                        onOpen: () => widget.onOpen(row.items[j].index),
                        onFocusChange: row.items[j].index == 0
                            ? widget.onFirstTileFocusChange
                            : null,
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  // Exposed for potential external relayout triggers.
  // ignore: unused_element
  double get lastWidth => _lastWidth;
}

class _GItem {
  _GItem({required this.index, required this.entry, required this.aspect});
  final int index;
  final MediaEntry entry;
  final double aspect;
}

class _GRow {
  _GRow({required this.items, required this.height});
  final List<_GItem> items;
  final double height;
}

class _MediaTile extends StatelessWidget {
  const _MediaTile({
    super.key,
    required this.entry,
    required this.width,
    required this.height,
    required this.onOpen,
    required this.maxDim,
    required this.quality,
    this.showTitle = false,
    this.autofocus = false,
    this.onFocusChange,
  });

  final MediaEntry entry;
  final double width;
  final double height;
  final VoidCallback onOpen;
  final int maxDim;
  final int quality;
  final bool showTitle;
  final bool autofocus;
  final ValueChanged<bool>? onFocusChange;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Focusable(
      autofocus: autofocus,
      onPressed: onOpen,
      onFocusChange: onFocusChange,
      builder: (context, focused) {
        return SizedBox(
          width: width,
          height: height,
          child: AnimatedContainer(
            duration: AppTheme.focusAnim,
            curve: AppTheme.emphasized,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(focused ? 14 : 10),
              border: Border.all(
                color: focused ? c.accent : Colors.transparent,
                width: 3,
              ),
              boxShadow: focused ? c.focusGlow() : null,
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(focused ? 11 : 8),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  CachedThumb(
                    entry: entry,
                    maxDim: maxDim,
                    quality: quality,
                    showInfo: !showTitle,
                  ),
                  if (showTitle)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: Container(
                        padding:
                            const EdgeInsets.fromLTRB(8, 14, 8, 6),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.transparent,
                              Colors.black.withValues(alpha: 0.6),
                            ],
                          ),
                        ),
                        child: Text(
                          entry.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
