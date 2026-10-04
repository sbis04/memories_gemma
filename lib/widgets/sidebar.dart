import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../core/app_theme.dart';
import '../models/media_entry.dart';
import 'focusable.dart';

/// A left drawer listing the current folder's siblings. It sits beside the
/// content (pushing it over) rather than floating above it, and is opened and
/// closed from the top bar's panel button. The browser owns the open state and
/// the slide animation; this widget is just the panel itself.
class Sidebar extends StatefulWidget {
  const Sidebar({
    super.key,
    required this.siblings,
    required this.currentPath,
    required this.onSelect,
    required this.currentFocusNode,
  });

  final List<MediaEntry> siblings;
  final String currentPath;
  final ValueChanged<String> onSelect;

  /// Attached to the current folder's row so the browser can move focus into
  /// the drawer when it opens.
  final FocusNode currentFocusNode;

  static const double width = 320;

  @override
  State<Sidebar> createState() => _SidebarState();
}

class _SidebarState extends State<Sidebar> {
  // Fixed row height so the list can start scrolled to the current folder —
  // its row is then built and can take focus as soon as the drawer opens.
  static const double _itemExtent = 52;
  late final ScrollController _scroll;

  int get _currentIndex {
    final i = widget.siblings.indexWhere((f) => f.path == widget.currentPath);
    return i < 0 ? 0 : i;
  }

  @override
  void initState() {
    super.initState();
    _scroll = ScrollController(
        initialScrollOffset: (_currentIndex - 2).clamp(0, 1 << 20) * _itemExtent);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      width: Sidebar.width,
      decoration: BoxDecoration(
        color: c.surface.withValues(alpha: 0.55),
        border: Border(right: BorderSide(color: c.hairline)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(26, 18, 18, 12),
            child: Text(
              'FOLDERS',
              style: TextStyle(
                color: c.textSecondary,
                fontSize: 13,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.6,
              ),
            ),
          ),
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              itemExtent: _itemExtent,
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
              itemCount: widget.siblings.length,
              itemBuilder: (context, i) {
                final folder = widget.siblings[i];
                final isCurrent = folder.path == widget.currentPath;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Focusable(
                    focusNode: isCurrent ? widget.currentFocusNode : null,
                    requestFocusOnHover: false,
                    onPressed: () => widget.onSelect(folder.path),
                    builder: (context, focused) => AnimatedContainer(
                      duration: AppTheme.focusAnim,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 13),
                      decoration: BoxDecoration(
                        color: focused
                            ? c.accent
                            : isCurrent
                                ? c.surfaceHigh
                                : Colors.transparent,
                        borderRadius: BorderRadius.circular(13),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            LucideIcons.folder,
                            size: 19,
                            color: focused
                                ? c.onAccent
                                : isCurrent
                                    ? c.textPrimary
                                    : c.textSecondary,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              folder.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: focused ? c.onAccent : c.textPrimary,
                                fontSize: 15,
                                fontWeight: isCurrent
                                    ? FontWeight.w600
                                    : FontWeight.w500,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
