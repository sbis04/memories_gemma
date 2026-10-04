import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:path/path.dart' as p;

import '../core/app_theme.dart';
import '../core/transitions.dart';
import '../models/media_entry.dart';
import '../services/file_ops.dart';
import '../services/media_scanner.dart';
import '../services/media_store_index.dart';
import '../services/settings_controller.dart';
import '../widgets/folder_actions.dart';
import '../widgets/icon_focus_button.dart';
import '../widgets/justified_gallery.dart';
import '../widgets/list_tiles.dart';
import '../widgets/polaroid_folder_card.dart';
import '../widgets/sidebar.dart';
import 'settings_screen.dart';
import 'slideshow_screen.dart';
import 'viewer_screen.dart';

/// Browses a single directory: subfolders as polaroid cards, media as a
/// justified gallery, with a collapsible sibling-folder sidebar.
class BrowserScreen extends StatefulWidget {
  const BrowserScreen({
    super.key,
    required this.rootPath,
    required this.currentPath,
    this.rootLabel,
    this.folderPanelOpen = false,
  });

  final String rootPath;
  final String currentPath;

  /// Start with the sibling-folders drawer open — set when switching folders
  /// from the drawer, so it stays open while hopping between siblings.
  final bool folderPanelOpen;

  /// Friendly name for the source root (e.g. "Internal Storage"), shown
  /// instead of the raw directory name (which for Android is literally "0").
  final String? rootLabel;

  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends State<BrowserScreen>
    with SingleTickerProviderStateMixin {
  final _settings = SettingsController.instance;
  DirectoryListing? _listing;
  List<MediaEntry> _media = const [];
  List<MediaEntry> _folders = const [];
  final Map<String, FolderSummary> _folderSummaries = {};
  List<MediaEntry> _siblings = const [];
  bool _loading = true;

  /// Folders are on screen but this folder's own media is still being fetched.
  bool _mediaLoading = false;

  /// Keeps the folder section's element (and the focused card) alive when the
  /// content switches from the folders-only list to the gallery as media lands.
  final GlobalKey _folderSectionKey = GlobalKey();
  bool _autofocusFirst = true; // only grab focus on first load, not refreshes
  SortBy? _lastSortBy;
  bool? _lastSortDesc;

  // Drives the "Back surfaces the top bar first" behaviour: when focus is in the
  // content and it's scrolled down, Back jumps focus to the top bar's first
  // button; pressing Back again (now on the top bar) leaves the page.
  final ScrollController _scrollController = ScrollController();
  final FocusNode _topBarScope =
      FocusNode(skipTraversal: true, canRequestFocus: false);
  bool _topBarFocused = false;

  // Sibling-folders drawer, toggled from the top bar. It pushes the content
  // over rather than overlaying it: the content resizes once (so the gallery
  // repacks once, not every frame) while the drawer slides into the gap.
  late final AnimationController _panel = AnimationController(
    vsync: this,
    duration: AppTheme.pageTransition,
    value: widget.folderPanelOpen ? 1 : 0,
  )..addStatusListener((_) {
      if (mounted) setState(() {});
    });
  /// Wraps the content (folders, then media) so focus can be put back on the
  /// item at a given position after a folder is renamed or deleted.
  final FocusNode _contentFocus =
      FocusNode(skipTraversal: true, canRequestFocus: false);
  final FocusNode _panelScope =
      FocusNode(skipTraversal: true, canRequestFocus: false);
  final FocusNode _panelCurrentFocus = FocusNode(debugLabel: 'panelCurrent');

  // Explicit focus nodes for the top-bar buttons so we can cycle Left/Right
  // among them deterministically — Flutter's geometric directional focus
  // otherwise escapes the bar into the photo grid.
  final FocusNode _backButtonFocus = FocusNode(debugLabel: 'tbBack');
  final FocusNode _panelToggleFocus = FocusNode(debugLabel: 'tbPanel');
  final FocusNode _resumeFocus = FocusNode(debugLabel: 'tbResume');
  final FocusNode _sortFocus = FocusNode(debugLabel: 'tbSort');
  final FocusNode _viewFocus = FocusNode(debugLabel: 'tbView');
  final FocusNode _zoomOutFocus = FocusNode(debugLabel: 'tbZoomOut');
  final FocusNode _zoomInFocus = FocusNode(debugLabel: 'tbZoomIn');
  final FocusNode _settingsFocus = FocusNode(debugLabel: 'tbSettings');

  /// The currently-visible (and enabled) top-bar buttons, left to right.
  List<FocusNode> _topBarNodes() => [
        _backButtonFocus,
        if (_hasPanel) _panelToggleFocus,
        if (_canResumeSlideshow) _resumeFocus,
        if (_media.isNotEmpty || _folders.isNotEmpty) _sortFocus,
        _viewFocus,
        if (_settings.gridZoom > 0) _zoomOutFocus,
        if (_settings.gridZoom < SettingsController.maxZoom) _zoomInFocus,
        _settingsFocus,
      ];

  /// Cycles focus across the top-bar buttons on Left/Right so the row stays
  /// self-contained (and the right-side buttons are reachable from Back).
  KeyEventResult _onTopBarKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final right = event.logicalKey == LogicalKeyboardKey.arrowRight;
    final left = event.logicalKey == LogicalKeyboardKey.arrowLeft;
    if (!right && !left) return KeyEventResult.ignored;
    final nodes = _topBarNodes();
    final i = nodes.indexWhere((n) => n.hasFocus);
    if (i < 0) return KeyEventResult.ignored;
    final next = i + (right ? 1 : -1);
    if (next >= 0 && next < nodes.length) nodes[next].requestFocus();
    return KeyEventResult.handled; // never let Left/Right escape the bar
  }

  bool get _isRoot => p.equals(widget.currentPath, widget.rootPath);

  /// The drawer only makes sense when there are sibling folders to hop to.
  bool get _hasPanel => !_isRoot && _siblings.length > 1;

  bool get _panelOpen =>
      _panel.status == AnimationStatus.forward ||
      _panel.status == AnimationStatus.completed;

  void _togglePanel() => _setPanelOpen(!_panelOpen);

  void _setPanelOpen(bool open) {
    if (open == _panelOpen) return;
    if (open) {
      _panel.forward();
      // Land on the folder you're in once the drawer's rows are focusable.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _panelCurrentFocus.context != null) {
          _panelCurrentFocus.requestFocus();
        }
      });
    } else {
      // Don't strand focus inside a drawer that's going away.
      if (_panelScope.hasFocus) _panelToggleFocus.requestFocus();
      _panel.reverse();
    }
  }

  /// On Android, true while the MediaStore is still indexing the drive — the
  /// folder's counts are still climbing.
  bool get _isScanning => _usesIndex && MediaStoreIndex.instance.isScanning;

  /// Browsing through the Android MediaStore index (vs. reading the drive).
  bool get _usesIndex => MediaScanner.instance.usesIndex(widget.currentPath);

  /// Media items currently known in this view: direct media if this folder has
  /// any, otherwise the recursive total across its subfolders (so a folder of
  /// folders still shows climbing progress while indexing).
  int get _mediaCountInView {
    if (_media.isNotEmpty) return _media.length;
    return _folders.fold<int>(
        0, (sum, f) => sum + (_folderSummaries[f.path]?.mediaCount ?? 0));
  }

  @override
  void initState() {
    super.initState();
    _settings.addListener(_onSettings);
    // On Android the MediaStore index keeps filling in as a USB drive is
    // scanned — refresh this screen whenever it updates.
    if (_usesIndex) {
      MediaStoreIndex.instance.addListener(_onIndexChanged);
      // If the app resumed straight into the browser (auto-open bypasses the
      // source screen) the index hasn't been built yet — build it now, or
      // nothing would ever load. The listener refreshes us once it's ready.
      if (!MediaStoreIndex.instance.isBuilt) {
        MediaStoreIndex.instance.build().then((ok) {
          // Permission denied — show the empty state rather than spinning.
          if (!ok && mounted) setState(() => _loading = false);
        });
      }
    }
    _topBarScope.addListener(_onTopBarFocus);
    // Arriving from the drawer: keep focus in the drawer, not the content.
    if (widget.folderPanelOpen) _autofocusFirst = false;
    _load();
    // Only the visible screen records itself: on resume the whole folder chain
    // is created at once, and the folders beneath mustn't overwrite it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && (ModalRoute.of(context)?.isCurrent ?? true)) {
        _settings.setLastFolder(widget.currentPath);
      }
    });
  }

  void _onTopBarFocus() {
    if (_topBarFocused != _topBarScope.hasFocus) {
      setState(() => _topBarFocused = _topBarScope.hasFocus);
    }
  }

  /// Back, in priority order:
  /// 1. If the folders drawer is open, close it.
  /// 2. If focus is in the content and it's scrolled down, surface the top bar.
  /// 3. Otherwise leave the page.
  void _handleBack() {
    if (_panelOpen) {
      _setPanelOpen(false);
      return;
    }
    final scrolled =
        _scrollController.hasClients && _scrollController.offset > 8;
    if (!_topBarFocused && scrolled) {
      _backButtonFocus.requestFocus();
    } else {
      Navigator.of(context).pop();
    }
  }

  void _onIndexChanged() {
    if (mounted) _load();
  }

  @override
  void dispose() {
    if (_usesIndex) {
      MediaStoreIndex.instance.removeListener(_onIndexChanged);
    }
    _settings.removeListener(_onSettings);
    _topBarScope.removeListener(_onTopBarFocus);
    _topBarScope.dispose();
    _panel.dispose();
    _panelScope.dispose();
    _contentFocus.dispose();
    _panelCurrentFocus.dispose();
    _panelToggleFocus.dispose();
    _backButtonFocus.dispose();
    _resumeFocus.dispose();
    _sortFocus.dispose();
    _viewFocus.dispose();
    _zoomOutFocus.dispose();
    _zoomInFocus.dispose();
    _settingsFocus.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onSettings() {
    if (!mounted) return;
    // Only re-sort (which produces a new media list) when the sort actually
    // changed — otherwise zoom/theme tweaks would recreate the list and force
    // the gallery to re-resolve every thumbnail.
    final sortChanged =
        _settings.sortBy != _lastSortBy || _settings.sortDesc != _lastSortDesc;
    setState(() {
      if (sortChanged) _applySort();
      // Pins may have changed — pinned folders lead the list.
      _folders = _sortFolders(_folders);
    });
  }

  Future<void> _load() async {
    final scanner = MediaScanner.instance;
    // On Android, folders are known synchronously from the index — paint them
    // on the first frame instead of waiting for this folder's media.
    if (_listing == null) {
      final quick = scanner.foldersNow(widget.currentPath);
      if (quick != null) {
        final siblings = _isRoot
            ? const <MediaEntry>[]
            : scanner.foldersNow(p.dirname(widget.currentPath)) ??
                const <MediaEntry>[];
        setState(() {
          _folders = _sortFolders(quick);
          _siblings = siblings;
          _loading = false;
          _mediaLoading = true;
        });
        _releaseAutofocus();
      } else if (_usesIndex && !MediaStoreIndex.instance.isBuilt) {
        // Index still being built — keep the spinner (rather than flashing
        // "Nothing here"); its listener calls us again once it's ready.
        return;
      } else if (!_usesIndex && scanner.scanOverride == null) {
        // Reading the drive: a folders-only listing is near-instant, so paint
        // those before the (slower) media listing.
        final folders = await scanner.folders(widget.currentPath);
        if (!mounted) return;
        if (_listing == null && folders.isNotEmpty) {
          setState(() {
            _folders = _sortFolders(folders);
            _loading = false;
            _mediaLoading = true;
          });
          _releaseAutofocus();
        }
      }
    }
    try {
      final listing = await scanner.scan(widget.currentPath);
      final siblings = _isRoot
          ? const <MediaEntry>[]
          : await scanner.folders(p.dirname(widget.currentPath));
      if (!mounted) return;
      setState(() {
        _listing = listing;
        _folders = _sortFolders(listing.folders);
        _siblings = siblings;
        _loading = false;
        _mediaLoading = false;
        _applySort();
      });
      // Once indexing has settled, remember this folder's total so the next scan
      // can show progress against it (x / y).
      if (!_isScanning) {
        unawaited(
            _settings.setFolderCount(widget.currentPath, _mediaCountInView));
      }
      _releaseAutofocus();
    } catch (_) {
      // Never get stuck on the spinner if a scan fails for any reason.
      if (mounted && (_loading || _mediaLoading)) {
        setState(() {
          _loading = false;
          _mediaLoading = false;
        });
      }
    }
  }

  /// Pinned folders first (in pin order), then folders with previews, then by
  /// date (when sorting by date) or name. Uses only summaries that are
  /// already known (instant on Android); on desktop each card computes its own
  /// in the background, so unknown folders are treated as non-empty rather than
  /// blocking the listing on a recursive walk of the drive.
  List<MediaEntry> _sortFolders(List<MediaEntry> folders) {
    for (final f in folders) {
      final s = MediaScanner.instance.cachedSummary(f.path);
      if (s != null) _folderSummaries[f.path] = s;
    }
    final pins = _settings.pinnedIn(widget.currentPath);
    int pinRank(MediaEntry f) {
      final i = pins.indexOf(f.path);
      return i < 0 ? pins.length : i;
    }
    int rank(MediaEntry f) {
      final s = _folderSummaries[f.path];
      return s == null || s.mediaCount > 0 ? 0 : 1;
    }
    // Sorting by date: the folder's first photo's capture date, following the
    // same direction toggle as photos. Folders whose date isn't known yet (not
    // counted before) go last, by name, rather than jumping as dates arrive.
    final byDate = _settings.sortBy == SortBy.date;
    int dateOrder(MediaEntry a, MediaEntry b) {
      final da = _folderSummaries[a.path]?.date;
      final db = _folderSummaries[b.path]?.date;
      if (da == null || db == null) return (da == null ? 1 : 0) - (db == null ? 1 : 0);
      final c = da.compareTo(db);
      return _settings.sortDesc ? -c : c;
    }
    return [...folders]..sort((a, b) {
        var c = pinRank(a) - pinRank(b);
        if (c != 0) return c;
        c = rank(a) - rank(b);
        if (c != 0) return c;
        if (byDate) {
          c = dateOrder(a, b);
          if (c != 0) return c;
        }
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
  }

  /// Stop auto-grabbing focus only once there's actually something to focus.
  /// On Android the folder/media list often arrives a beat after the first
  /// (empty) load as the MediaStore finishes indexing — keep trying until then,
  /// so the first item gets focus. Once shown, background refreshes won't yank
  /// the user's selection.
  void _releaseAutofocus() {
    if (_autofocusFirst && (_folders.isNotEmpty || _media.isNotEmpty)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _autofocusFirst = false;
      });
    }
  }

  void _applySort() {
    final listing = _listing;
    if (listing == null) return;
    final media = [...listing.media];
    media.sort((a, b) {
      int c;
      if (_settings.sortBy == SortBy.date) {
        c = a.modified.compareTo(b.modified);
      } else {
        c = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      }
      return _settings.sortDesc ? -c : c;
    });
    _media = media;
    _lastSortBy = _settings.sortBy;
    _lastSortDesc = _settings.sortDesc;
  }

  Future<void> _openFolder(String path) async {
    await Navigator.of(context).push(
      FadeZoomPageRoute(
        child: BrowserScreen(
            rootPath: widget.rootPath,
            currentPath: path,
            rootLabel: widget.rootLabel),
      ),
    );
    // Back here again — resume into this folder, not the one we just left.
    if (mounted) unawaited(_settings.setLastFolder(widget.currentPath));
  }

  void _openSibling(String path) {
    Navigator.of(context).pushReplacement(
      FadeZoomPageRoute(
        child: BrowserScreen(
            rootPath: widget.rootPath,
            currentPath: path,
            rootLabel: widget.rootLabel,
            folderPanelOpen: true),
      ),
    );
  }

  void _openViewer(int index) {
    Navigator.of(context).push(
      FadeZoomPageRoute(
        child: ViewerScreen(
          media: _media,
          initialIndex: index,
          folderPath: widget.currentPath,
        ),
      ),
    );
  }

  /// Resumes the slideshow that was last running in this folder, starting from
  /// the item it stopped on. When the slideshow exits, open that item in the
  /// viewer so the stopped photo is shown.
  Future<void> _resumeSlideshow() async {
    final itemPath = _settings.slideshowLastItem;
    var start = 0;
    if (itemPath != null) {
      final i = _media.indexWhere((m) => m.path == itemPath);
      if (i >= 0) start = i;
    }
    final stoppedAt = await Navigator.of(context).push<int>(
      FadeZoomPageRoute(
        child: SlideshowScreen(
          media: _media,
          startIndex: start,
          folderPath: widget.currentPath,
        ),
      ),
    );
    if (stoppedAt != null && mounted) _openViewer(stoppedAt);
  }

  /// Whether this folder has a resumable slideshow (one ran here before and the
  /// folder still has media to play).
  bool get _canResumeSlideshow {
    final folder = _settings.slideshowLastFolder;
    return _media.isNotEmpty &&
        folder != null &&
        p.equals(folder, widget.currentPath);
  }

  void _openSettings() {
    Navigator.of(context).push(FadeZoomPageRoute(child: const SettingsScreen()));
  }

  /// Friendly name for the source root — avoids showing Android's raw "0".
  String get _rootName {
    if (widget.rootLabel != null) return widget.rootLabel!;
    final base = p.basename(widget.rootPath);
    if (base.isEmpty || int.tryParse(base) != null) return 'Internal Storage';
    return base;
  }

  String get _title =>
      _isRoot ? _rootName : p.basename(widget.currentPath);

  String get _subtitle {
    final folders = _folders.length;
    final count = _media.length;
    final parts = <String>[];
    if (count > 0) {
      // While indexing, show progress against the last-known total if we have
      // one (Android doesn't report the drive's real total until it settles).
      final estimate = _settings.folderCount(widget.currentPath);
      if (_isScanning && estimate != null && estimate > count) {
        parts.add('$count / $estimate items');
      } else {
        parts.add('$count ${count == 1 ? "item" : "items"}');
      }
    }
    if (folders > 0) {
      parts.add('$folders ${folders == 1 ? "folder" : "folders"}');
    }
    if (!_isRoot) {
      // Breadcrumb relative to the root, prefixed with the friendly root name.
      final rel = p.relative(widget.currentPath, from: widget.rootPath);
      final crumb = [_rootName, ...rel.split('/')].join('  ›  ');
      return '${parts.join("  ·  ")}${parts.isEmpty ? "" : "      "}$crumb';
    }
    return parts.isEmpty ? 'Empty' : parts.join('  ·  ');
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    const topBarHeight = 96.0;
    // The drawer's slot is reserved for the whole open/close animation and
    // only collapses once it has fully slid out.
    final panelVisible = _hasPanel && !_panel.isDismissed;

    return PopScope(
      // Always intercept Back so we can surface the top bar first when the
      // content is scrolled down (see _handleBack).
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleBack();
      },
      child: Scaffold(
      backgroundColor: Colors.transparent,
      body: Container(
        decoration: c.backgroundDecoration,
        child: Stack(
          children: [
            Column(
              children: [
                Focus(
                  // Monitor (don't take) focus so we know when the top bar is
                  // focused — Back from there leaves the page — and handle
                  // Left/Right to cycle across the bar's buttons.
                  focusNode: _topBarScope,
                  canRequestFocus: false,
                  skipTraversal: true,
                  onKeyEvent: _onTopBarKey,
                  child: _TopBar(
                    height: topBarHeight,
                    title: _title,
                    subtitle: _subtitle,
                    loading: _isScanning,
                    zoom: _settings.gridZoom,
                    showSort: _media.isNotEmpty || _folders.isNotEmpty,
                    sortDesc: _settings.sortDesc,
                    onToggleSort: () =>
                        _settings.setSortDesc(!_settings.sortDesc),
                    listView: _settings.listView,
                    onToggleView: () =>
                        _settings.setListView(!_settings.listView),
                    viewFocusNode: _viewFocus,
                    showResume: _canResumeSlideshow,
                    onResume: _resumeSlideshow,
                    onBack: _handleBack,
                    backFocusNode: _backButtonFocus,
                    showPanelToggle: _hasPanel,
                    panelOpen: _panelOpen,
                    onTogglePanel: _togglePanel,
                    panelToggleFocusNode: _panelToggleFocus,
                    resumeFocusNode: _resumeFocus,
                    sortFocusNode: _sortFocus,
                    zoomOutFocusNode: _zoomOutFocus,
                    zoomInFocusNode: _zoomInFocus,
                    settingsFocusNode: _settingsFocus,
                    onZoomIn: _settings.gridZoom < SettingsController.maxZoom
                        ? () => _settings.zoomIn()
                        : null,
                    onZoomOut:
                        _settings.gridZoom > 0 ? () => _settings.zoomOut() : null,
                    onSettings: _openSettings,
                  ),
                ),
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (panelVisible)
                        ClipRect(
                          child: SizedBox(
                            width: Sidebar.width,
                            child: AnimatedBuilder(
                              animation: _panel,
                              builder: (context, child) {
                                final t = AppTheme.emphasized
                                    .transform(_panel.value);
                                return FractionalTranslation(
                                  translation: Offset(t - 1, 0),
                                  child: Opacity(opacity: t, child: child),
                                );
                              },
                              child: ExcludeFocus(
                                excluding: !_panelOpen,
                                child: FocusTraversalGroup(
                                  child: Focus(
                                    focusNode: _panelScope,
                                    child: Sidebar(
                                      siblings: _siblings,
                                      currentPath: widget.currentPath,
                                      onSelect: _openSibling,
                                      currentFocusNode: _panelCurrentFocus,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      Expanded(
                        // Its own focus group (sibling to the top bar's) so
                        // D-pad Up from anywhere in the content climbs back
                        // into the top bar — landing on the nearest button,
                        // including the right-side ones — instead of getting
                        // stuck among the items.
                        child: Focus(
                          focusNode: _contentFocus,
                          canRequestFocus: false,
                          skipTraversal: true,
                          child: FocusTraversalGroup(child: _buildContent(c)),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      ),
    );
  }

  /// Hold OK on a folder: pin/unpin, and — on a real drive — rename/delete.
  Future<void> _folderMenu(MediaEntry folder) async {
    final action = await showFolderActions(
      context,
      name: folder.name,
      pinned: _settings.isPinned(folder.path),
      canEdit: !_usesIndex,
    );
    if (!mounted || action == null) return;
    try {
      switch (action) {
        case FolderAction.pin:
          final pinned = await _settings.togglePin(folder.path);
          _toast(pinned
              ? 'Pinned “${folder.name}”'
              : 'Unpinned “${folder.name}”');
        case FolderAction.rename:
          await _rename(folder);
        case FolderAction.delete:
          await _delete(folder);
      }
    } catch (e) {
      _toast('Something went wrong: $e');
    }
  }

  Future<void> _rename(MediaEntry folder) async {
    final name = await showRenameDialog(context, name: folder.name);
    if (!mounted || name == null) return;
    try {
      final renamed = await FileOps.rename(folder.path, name);
      MediaScanner.instance.forget(folder.path);
      await _settings.movePinned(folder.path, renamed);
      _replaceFolder(folder.path, renamed);
      _toast('Renamed to “${p.basename(renamed)}”');
    } on FileOpException catch (e) {
      _toast('Couldn’t rename: ${e.message}');
    }
  }

  Future<void> _delete(MediaEntry folder) async {
    final s = _folderSummaries[folder.path] ??
        MediaScanner.instance.cachedSummary(folder.path);
    final what = s == null || s.isEmpty
        ? 'This folder'
        : 'This folder and everything in it '
            '(${PolaroidFolderCard.countLabel(s)})';
    final ok = await showDeleteDialog(
      context,
      name: folder.name,
      detail: '$what will be permanently deleted from the drive. '
          'This can’t be undone.',
    );
    if (!mounted || !ok) return;
    try {
      await FileOps.delete(folder.path);
      _toast('Deleted “${folder.name}”');
    } on FileOpException catch (e) {
      // Partly deleted at worst — re-list so what's shown matches the drive.
      _toast('Couldn’t delete: ${e.message}');
      MediaScanner.instance.forget(folder.path);
      await _load();
      return;
    }
    MediaScanner.instance.forget(folder.path);
    await _settings.movePinned(folder.path, null);
    _replaceFolder(folder.path, null);
  }

  /// Applies a rename ([newPath]) or delete (null) of the subfolder at
  /// [oldPath] to what's on screen directly — re-listing straight away can
  /// briefly return the old name from Android's USB layer — then puts focus
  /// on the renamed folder, or the one that took the deleted one's place.
  void _replaceFolder(String oldPath, String? newPath) {
    var index = _folders.indexWhere((f) => f.path == oldPath);
    MediaEntry? swap(MediaEntry e) => e.path != oldPath
        ? e
        : newPath == null
            ? null
            : MediaEntry(
                path: newPath, type: EntryType.folder, modified: e.modified);
    setState(() {
      final listing = _listing;
      if (listing != null) {
        _listing = DirectoryListing(
          path: listing.path,
          entries: [for (final e in listing.entries) ?swap(e)],
        );
      }
      _folders = _sortFolders([for (final f in _folders) ?swap(f)]);
    });
    if (newPath != null) index = _folders.indexWhere((f) => f.path == newPath);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final nodes = _contentFocus.traversalDescendants.toList();
      if (nodes.isEmpty || index < 0) return;
      nodes[index.clamp(0, nodes.length - 1)].requestFocus();
    });
  }

  void _toast(String message) {
    if (!mounted) return;
    final c = context.colors;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        behavior: SnackBarBehavior.floating,
        width: 460,
        duration: const Duration(seconds: 2),
        backgroundColor: c.surfaceHigh,
        content: Text(
          message,
          style: TextStyle(color: c.textPrimary, fontSize: 15),
        ),
      ));
  }

  /// The list layout: Folders, then Photos & Videos as rows, built
  /// lazily so folders with thousands of items stay cheap.
  Widget _buildList(GalleryColors c) {
    final rowH = _settings.listRowHeight;
    final rows = <Widget Function(bool autofocus)>[];
    final focusable = <bool>[];
    void label(String text, {double top = 0}) {
      rows.add((_) => Padding(
            padding: EdgeInsets.only(top: top, bottom: 12, left: 6),
            child: _SectionLabel(label: text),
          ));
      focusable.add(false);
    }

    void folderRows(List<MediaEntry> folders) {
      for (final f in folders) {
        rows.add((autofocus) => FolderListTile(
              key: ValueKey(f.path),
              folder: f,
              height: rowH,
              autofocus: autofocus,
              pinned: _settings.isPinned(f.path),
              summary: _folderSummaries[f.path],
              onOpen: () => _openFolder(f.path),
              onLongPress: () => _folderMenu(f),
            ));
        focusable.add(true);
      }
    }

    if (_folders.isNotEmpty) {
      label('FOLDERS');
      folderRows(_folders);
    }
    if (_media.isNotEmpty) {
      label('PHOTOS & VIDEOS', top: _folders.isNotEmpty ? 22 : 0);
      for (var i = 0; i < _media.length; i++) {
        final index = i;
        rows.add((autofocus) => MediaListTile(
              key: ValueKey(_media[index].path),
              entry: _media[index],
              height: rowH,
              autofocus: autofocus,
              onOpen: () => _openViewer(index),
            ));
        focusable.add(true);
      }
    }
    final firstFocusable = focusable.indexOf(true);

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(34, 8, 34, 110),
      itemCount: rows.length + (_mediaLoading ? 1 : 0),
      itemBuilder: (context, i) {
        if (i == rows.length) {
          return const Padding(
            padding: EdgeInsets.only(top: 24),
            child: Center(
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }
        return rows[i](_autofocusFirst && i == firstFocusable);
      },
    );
  }

  Widget _buildContent(GalleryColors c) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final hasFolders = _folders.isNotEmpty;
    final hasMedia = _media.isNotEmpty;

    if (!hasFolders && !hasMedia) {
      if (_mediaLoading) return const Center(child: CircularProgressIndicator());
      return _EmptyState(isRoot: _isRoot);
    }

    if (_settings.listView) return _buildList(c);

    final folderHeader = hasFolders
        ? KeyedSubtree(
            key: _folderSectionKey,
            child: _buildFolderSection(c, _folders),
          )
        : null;

    if (!hasMedia) {
      // Folders only — just render the section in a scroll view (with a quiet
      // spinner beneath while this folder's own photos are still loading).
      return ListView(
        controller: _scrollController,
        padding: const EdgeInsets.fromLTRB(40, 8, 40, 110),
        children: [
          folderHeader!,
          if (_mediaLoading)
            const Padding(
              padding: EdgeInsets.only(top: 24),
              child: Center(
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
        ],
      );
    }

    return JustifiedGallery(
      media: _media,
      rowHeight: _settings.galleryRowHeight,
      showTitles: _settings.showTitles,
      onOpen: _openViewer,
      autofocusFirst: !hasFolders && _autofocusFirst,
      scrollController: _scrollController,
      padding: const EdgeInsets.fromLTRB(40, 8, 40, 110),
      header: folderHeader,
    );
  }

  Widget _buildFolderSection(GalleryColors c, List<MediaEntry> folders) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const spacing = 18.0;
        final maxW = constraints.maxWidth;
        // Pick the column count that keeps cards near the zoom level's target
        // width, then stretch them to fill the row exactly (no trailing gap).
        final target = _settings.folderCardWidth;
        final cols = (maxW / target).round().clamp(1, 10);
        final cardW = (maxW - spacing * (cols - 1)) / cols;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _SectionLabel(label: 'FOLDERS'),
            const SizedBox(height: 14),
            Wrap(
              spacing: spacing,
              runSpacing: 18,
              children: [
                for (var i = 0; i < folders.length; i++)
                  PolaroidFolderCard(
                    key: ValueKey(folders[i].path),
                    width: cardW,
                    folder: folders[i],
                    autofocus: i == 0 && _autofocusFirst,
                    summary: _folderSummaries[folders[i].path],
                    pinned: _settings.isPinned(folders[i].path),
                    onOpen: () => _openFolder(folders[i].path),
                    onLongPress: () => _folderMenu(folders[i]),
                  ),
              ],
            ),
            if (_media.isNotEmpty) ...[
              const SizedBox(height: 26),
              const _SectionLabel(label: 'PHOTOS & VIDEOS'),
              const SizedBox(height: 14),
            ] else
              const SizedBox(height: 8),
          ],
        );
      },
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Text(
      label,
      style: TextStyle(
        color: c.textSecondary,
        fontSize: 13,
        fontWeight: FontWeight.w800,
        letterSpacing: 1.6,
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.height,
    required this.title,
    required this.subtitle,
    required this.loading,
    required this.zoom,
    required this.onBack,
    required this.onSettings,
    required this.showSort,
    required this.sortDesc,
    required this.onToggleSort,
    required this.listView,
    required this.onToggleView,
    required this.viewFocusNode,
    required this.showResume,
    required this.onResume,
    required this.backFocusNode,
    required this.showPanelToggle,
    required this.panelOpen,
    required this.onTogglePanel,
    required this.panelToggleFocusNode,
    required this.resumeFocusNode,
    required this.sortFocusNode,
    required this.zoomOutFocusNode,
    required this.zoomInFocusNode,
    required this.settingsFocusNode,
    this.onZoomIn,
    this.onZoomOut,
  });

  final double height;
  final String title;
  final String subtitle;
  final bool loading;
  final int zoom;
  final bool showSort;
  final bool sortDesc;
  final VoidCallback onToggleSort;
  final bool listView;
  final VoidCallback onToggleView;
  final FocusNode viewFocusNode;
  final bool showResume;
  final VoidCallback onResume;
  final VoidCallback onBack;
  final FocusNode backFocusNode;
  final bool showPanelToggle;
  final bool panelOpen;
  final VoidCallback onTogglePanel;
  final FocusNode panelToggleFocusNode;
  final FocusNode resumeFocusNode;
  final FocusNode sortFocusNode;
  final FocusNode zoomOutFocusNode;
  final FocusNode zoomInFocusNode;
  final FocusNode settingsFocusNode;
  final VoidCallback onSettings;
  final VoidCallback? onZoomIn;
  final VoidCallback? onZoomOut;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    // Group the bar so D-pad Left/Right moves between its buttons (e.g. Right
    // from Back lands on the leftmost right-aligned button) instead of escaping
    // down into the photo grid; Up/Down still crosses to the content.
    return FocusTraversalGroup(
      child: Container(
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Row(
        children: [
          IconFocusButton(
              icon: LucideIcons.arrowLeft,
              onPressed: onBack,
              focusNode: backFocusNode),
          if (showPanelToggle) ...[
            const SizedBox(width: 10),
            IconFocusButton(
              icon: panelOpen
                  ? LucideIcons.panelLeftClose
                  : LucideIcons.panelLeftOpen,
              onPressed: onTogglePanel,
              focusNode: panelToggleFocusNode,
            ),
          ],
          const SizedBox(width: 20),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: AppTheme.displayFont,
                    color: c.textPrimary,
                    fontSize: 40,
                    height: 1.0,
                    letterSpacing: 0.2,
                  ),
                ),
                const SizedBox(height: 3),
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: c.textFaint,
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    if (loading) ...[
                      const SizedBox(width: 10),
                      Opacity(
                        opacity: 0.35,
                        child: SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.6,
                            color: c.textFaint,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          if (showResume) ...[
            IconFocusButton(
              icon: LucideIcons.play,
              label: 'Resume',
              onPressed: onResume,
              focusNode: resumeFocusNode,
            ),
            const SizedBox(width: 10),
          ],
          if (showSort) ...[
            IconFocusButton(
              icon: sortDesc
                  ? LucideIcons.arrowDownWideNarrow
                  : LucideIcons.arrowUpNarrowWide,
              onPressed: onToggleSort,
              focusNode: sortFocusNode,
            ),
            const SizedBox(width: 10),
          ],
          IconFocusButton(
            // Shows the layout you'd switch to.
            icon: listView ? LucideIcons.layoutGrid : LucideIcons.list,
            onPressed: onToggleView,
            focusNode: viewFocusNode,
          ),
          const SizedBox(width: 10),
          IconFocusButton(
            icon: LucideIcons.zoomOut,
            onPressed: onZoomOut ?? () {},
            enabled: onZoomOut != null,
            focusNode: zoomOutFocusNode,
          ),
          const SizedBox(width: 10),
          IconFocusButton(
            icon: LucideIcons.zoomIn,
            onPressed: onZoomIn ?? () {},
            enabled: onZoomIn != null,
            focusNode: zoomInFocusNode,
          ),
          const SizedBox(width: 16),
          IconFocusButton(
              icon: LucideIcons.sliders,
              onPressed: onSettings,
              focusNode: settingsFocusNode),
        ],
      ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.isRoot});
  final bool isRoot;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(LucideIcons.imageOff, size: 50, color: c.textFaint),
          const SizedBox(height: 18),
          Text(
            'Nothing here yet',
            style: TextStyle(
                color: c.textSecondary,
                fontSize: 20,
                fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Text(
            isRoot
                ? 'This source has no photos, videos or folders.'
                : 'This folder is empty.',
            style: TextStyle(color: c.textFaint, fontSize: 15),
          ),
        ],
      ),
    );
  }
}

/// Helper to check if a directory still exists (used during auto-open).
bool directoryExists(String path) => Directory(path).existsSync();
