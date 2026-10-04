import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../core/app_theme.dart';
import '../models/media_entry.dart';
import '../services/media_scanner.dart';
import 'cached_thumb.dart';
import 'focusable.dart';
import 'media_caption.dart';
import 'polaroid_folder_card.dart';
import 'visibility_gate.dart';

/// Shared row chrome for the browser's list view: a square thumbnail, a title
/// and a detail line, with a trailing glyph. Full-width rows don't scale on
/// focus (they'd overflow); they lift with a fill and accent border instead.
class _ListRow extends StatelessWidget {
  const _ListRow({
    required this.height,
    required this.thumb,
    required this.title,
    required this.detail,
    required this.trailing,
    required this.onOpen,
    this.autofocus = false,
    this.onLongPress,
    this.pinned = false,
  });

  final double height;
  final Widget thumb;
  final String title;
  final String detail;
  final IconData? trailing;
  final VoidCallback onOpen;
  final bool autofocus;
  final VoidCallback? onLongPress;
  final bool pinned;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final thumbSize = height - 12;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Focusable(
        autofocus: autofocus,
        onPressed: onOpen,
        onLongPress: onLongPress,
        focusScale: 1.0,
        builder: (context, focused) => AnimatedContainer(
          duration: AppTheme.focusAnim,
          curve: AppTheme.emphasized,
          height: height,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          decoration: BoxDecoration(
            color: focused ? c.surfaceHigh : Colors.transparent,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: focused ? c.accent : Colors.transparent,
              width: 2,
            ),
            boxShadow: focused ? c.focusGlow(intensity: 0.5) : null,
          ),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(width: thumbSize, height: thumbSize, child: thumb),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (pinned) ...[
                          Icon(LucideIcons.pin, size: 14, color: c.accent),
                          const SizedBox(width: 6),
                        ],
                        Flexible(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: c.textPrimary,
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (detail.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        detail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: c.textFaint, fontSize: 13),
                      ),
                    ],
                  ],
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: 12),
                Icon(trailing, size: 20, color: c.textFaint),
                const SizedBox(width: 10),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A folder row: cover thumbnail, name, and item/folder counts. Loads its own
/// summary when the browser hasn't supplied one.
class FolderListTile extends StatefulWidget {
  const FolderListTile({
    super.key,
    required this.folder,
    required this.height,
    required this.onOpen,
    this.summary,
    this.autofocus = false,
    this.pinned = false,
    this.onLongPress,
  });

  final MediaEntry folder;
  final double height;
  final VoidCallback onOpen;
  final FolderSummary? summary;
  final bool autofocus;
  final bool pinned;
  final VoidCallback? onLongPress;

  @override
  State<FolderListTile> createState() => _FolderListTileState();
}

class _FolderListTileState extends State<FolderListTile>
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
  void didUpdateWidget(FolderListTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    final s = widget.summary;
    if (s != null && !identical(s, oldWidget.summary)) _summary = s;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final cover = _summary?.cover;
    return _ListRow(
      height: widget.height,
      autofocus: widget.autofocus,
      onOpen: widget.onOpen,
      onLongPress: widget.onLongPress,
      pinned: widget.pinned,
      title: widget.folder.name,
      detail: PolaroidFolderCard.countLabel(_summary),
      trailing: LucideIcons.chevronRight,
      thumb: cover == null
          ? ColoredBox(
              color: c.surface,
              child: Icon(LucideIcons.folder, color: c.textFaint, size: 22),
            )
          : CachedThumb(
              entry: cover,
              maxDim: 240,
              quality: 60,
              showVideoBadge: false,
            ),
    );
  }
}

/// A photo/video row: thumbnail, name, and capture date · file size.
class MediaListTile extends StatelessWidget {
  const MediaListTile({
    super.key,
    required this.entry,
    required this.height,
    required this.onOpen,
    this.autofocus = false,
  });

  final MediaEntry entry;
  final double height;
  final VoidCallback onOpen;
  final bool autofocus;

  static String _size(int bytes) {
    if (bytes <= 0) return '';
    const mb = 1024 * 1024;
    if (bytes >= 1024 * mb) return '${(bytes / (1024 * mb)).toStringAsFixed(1)} GB';
    if (bytes >= mb) return '${(bytes / mb).toStringAsFixed(1)} MB';
    return '${(bytes / 1024).ceil()} KB';
  }

  @override
  Widget build(BuildContext context) {
    final parts = [
      if (entry.modified.millisecondsSinceEpoch > 0)
        MediaCaption.formatDate(entry.modified),
      _size(entry.size),
    ].where((s) => s.isNotEmpty);
    return _ListRow(
      height: height,
      autofocus: autofocus,
      onOpen: onOpen,
      title: entry.displayName,
      detail: parts.join('  ·  '),
      trailing: entry.isVideo ? LucideIcons.play : null,
      thumb: CachedThumb(
        entry: entry,
        maxDim: 240,
        quality: 60,
        showVideoBadge: false,
      ),
    );
  }
}
