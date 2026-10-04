import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../core/app_theme.dart';
import '../models/media_entry.dart';
import '../services/media_scanner.dart';
import 'cached_thumb.dart';
import 'focusable.dart';
import 'visibility_gate.dart';

/// A folder rendered as a stack of polaroid photos with a title and a media
/// count beneath it — the home-screen folder affordance.
class PolaroidFolderCard extends StatefulWidget {
  const PolaroidFolderCard({
    super.key,
    required this.folder,
    required this.onOpen,
    this.autofocus = false,
    this.onFocusChange,
    this.summary,
    this.width,
    this.pinned = false,
    this.onLongPress,
  });

  final MediaEntry folder;
  final VoidCallback onOpen;
  final bool autofocus;
  final ValueChanged<bool>? onFocusChange;

  /// Optionally pre-computed summary (the browser computes these to order
  /// folders with previews first); when null the card loads its own.
  final FolderSummary? summary;

  /// The card's width. The browser sizes cards to fill the row evenly; defaults
  /// to [defaultWidth] when laid out on its own. Height is intrinsic.
  final double? width;

  /// Shows a pin beside the name.
  final bool pinned;

  /// Holding OK on the card (used to pin / unpin it).
  final VoidCallback? onLongPress;

  static const double defaultWidth = 220;

  /// "12 items · 3 folders", "Empty", or "…" while still counting.
  static String countLabel(FolderSummary? s) {
    if (s == null) return '…';
    if (s.isEmpty) return 'Empty';
    final parts = <String>[];
    if (s.mediaCount > 0) {
      parts.add('${s.mediaCount} ${s.mediaCount == 1 ? "item" : "items"}');
    }
    if (s.subfolderCount > 0) {
      parts.add(
          '${s.subfolderCount} ${s.subfolderCount == 1 ? "folder" : "folders"}');
    }
    return parts.join('  ·  ');
  }

  @override
  State<PolaroidFolderCard> createState() => _PolaroidFolderCardState();
}

class _PolaroidFolderCardState extends State<PolaroidFolderCard>
    with VisibilityGate {
  FolderSummary? _summary;

  @override
  void initState() {
    super.initState();
    _summary = widget.summary;
  }

  bool _requested = false;

  /// Counts the folder only while its screen is showing; covered screens
  /// stop their walk so the folder being viewed gets the drive.
  @override
  void onVisibilityChanged(bool visible) {
    // A summary saved from a previous session is shown straight away but still
    // refreshed (the drive may have changed).
    if (_summary != null &&
        MediaScanner.instance.isFresh(widget.folder.path)) {
      return;
    }
    final scanner = MediaScanner.instance;
    if (visible && !_requested) {
      _requested = true;
      scanner.summarize(widget.folder.path).then((s) {
        _requested = false;
        if (!mounted) return;
        if (s != null) {
          setState(() => _summary = s);
        } else if (isVisible) {
          onVisibilityChanged(true); // cancelled, but we're back — retry
        }
      });
    } else if (!visible && _requested) {
      scanner.cancelSummarize(widget.folder.path);
    }
  }

  @override
  void dispose() {
    if (_requested) MediaScanner.instance.cancelSummarize(widget.folder.path);
    super.dispose();
  }


  @override
  void didUpdateWidget(PolaroidFolderCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The browser re-supplies summaries as the index fills in (e.g. while a USB
    // drive is still being scanned) — keep the count and cover current.
    final s = widget.summary;
    if (s != null && !identical(s, oldWidget.summary)) _summary = s;
  }

  String get _countLabel => PolaroidFolderCard.countLabel(_summary);

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Focusable(
      autofocus: widget.autofocus,
      onPressed: widget.onOpen,
      onLongPress: widget.onLongPress,
      onFocusChange: widget.onFocusChange,
      builder: (context, focused) {
        return SizedBox(
          width: widget.width ?? PolaroidFolderCard.defaultWidth,
          child: AnimatedContainer(
            duration: AppTheme.focusAnim,
            curve: AppTheme.emphasized,
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
            decoration: BoxDecoration(
              color: focused ? c.surfaceHigh : Colors.transparent,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(
                color: focused ? c.accent.withValues(alpha: 0.9) : Colors.transparent,
                width: 1.5,
              ),
              boxShadow: focused ? c.focusGlow(intensity: 0.7) : null,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AspectRatio(
                  aspectRatio: 1.32,
                  child: _PolaroidStack(summary: _summary),
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (widget.pinned) ...[
                      Icon(LucideIcons.pin, size: 15, color: c.accent),
                      const SizedBox(width: 6),
                    ],
                    Flexible(
                      child: Text(
                        widget.folder.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: c.textPrimary,
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.1,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  _countLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: c.textFaint,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// The stacked-photo visual: two tilted backing cards + the cover on top.
class _PolaroidStack extends StatelessWidget {
  const _PolaroidStack({required this.summary});
  final FolderSummary? summary;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final cover = summary?.cover;

    Widget polaroid({double angle = 0, Widget? child, double scale = 1}) {
      return Transform.rotate(
        angle: angle,
        child: Transform.scale(
          scale: scale,
          child: Container(
            decoration: BoxDecoration(
              color: c.polaroid,
              borderRadius: BorderRadius.circular(6),
              boxShadow: [
                BoxShadow(
                  color: c.shadow.withValues(alpha: 0.45),
                  blurRadius: 14,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            padding: const EdgeInsets.all(5),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: child ?? const SizedBox.expand(),
            ),
          ),
        ),
      );
    }

    return Stack(
      alignment: Alignment.center,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: polaroid(angle: -0.09, scale: 0.9),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 3),
          child: polaroid(angle: 0.07, scale: 0.95),
        ),
        polaroid(
          angle: 0.0,
          child: cover == null
              ? Center(
                  child: Icon(LucideIcons.folder, color: c.textFaint, size: 34),
                )
              : CachedThumb(
                  entry: cover,
                  maxDim: 480,
                  quality: 60,
                  showVideoBadge: false,
                ),
        ),
      ],
    );
  }
}
