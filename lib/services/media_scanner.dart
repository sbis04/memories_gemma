import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/media_entry.dart';
import 'android_files.dart';
import 'media_store_index.dart';

/// Walks the filesystem and classifies entries into folders / images / videos.
class MediaScanner {
  MediaScanner._();
  static final MediaScanner instance = MediaScanner._();

  static const Set<String> imageExts = {
    '.heic', '.heif', '.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp',
    '.tif', '.tiff',
  };
  static const Set<String> videoExts = {
    '.mov', '.mp4', '.m4v', '.avi', '.mkv', '.3gp', '.webm', '.mpg', '.mpeg',
  };

  final Map<String, FolderSummary> _summaryCache = {};
  /// Paths whose summary was (re)computed this session; anything else in
  /// [_summaryCache] came from disk and is shown while being refreshed.
  final Set<String> _fresh = {};
  File? _store;
  Timer? _saveTimer;
  final Map<String, Future<FolderSummary?>> _summaryInflight = {};
  final Map<String, int> _summaryIds = {};
  int _nextSummaryId = 0;

  /// Test seams: when set, bypass the filesystem so widget & golden tests can
  /// supply deterministic in-memory data.
  DirectoryListing Function(String path)? scanOverride;
  FolderSummary Function(String path)? summarizeOverride;

  /// Whether [path] is browsed through the Android MediaStore index (virtual
  /// paths) rather than read directly from the filesystem — real `/storage`
  /// paths on Android (with All files access), and everything on desktop.
  bool usesIndex(String path) =>
      Platform.isAndroid && !AndroidFiles.isRealPath(path);

  EntryType? _classify(String name) {
    final ext = p.extension(name).toLowerCase();
    if (imageExts.contains(ext)) return EntryType.image;
    if (videoExts.contains(ext)) return EntryType.video;
    return null;
  }

  /// Hidden files, macOS AppleDouble (`._x`) sidecars and system folders.
  bool _isIgnored(String name) =>
      name.startsWith('.') ||
      name == 'System Volume Information' ||
      name == r'$RECYCLE.BIN' ||
      name == 'LOST.DIR';

  /// Subfolders of [dirPath] available *synchronously* — on Android they come
  /// straight from the in-memory index, so the browser can paint folder cards
  /// on its first frame while the folder's own media is still being fetched.
  /// Null when there's no instant answer (other platforms, or index not built).
  List<MediaEntry>? foldersNow(String dirPath) {
    if (scanOverride != null) return null;
    if (usesIndex(dirPath) && MediaStoreIndex.instance.isBuilt) {
      return MediaStoreIndex.instance.foldersOf(dirPath);
    }
    return null;
  }

  /// Subfolders only — cheaper than [scan] (no media, no per-file stat).
  Future<List<MediaEntry>> folders(String dirPath) async {
    if (scanOverride != null) return scanOverride!(dirPath).folders;
    if (usesIndex(dirPath)) return MediaStoreIndex.instance.foldersOf(dirPath);
    // dart:io stats every entry it lists, which over Android's USB FUSE mount
    // takes many seconds for a big folder — list natively instead.
    if (Platform.isAndroid) {
      return (await AndroidFiles.dirs(dirPath))
        ..sort((a, b) => _naturalCompare(a.name, b.name));
    }
    final out = <MediaEntry>[];
    try {
      await for (final ent in Directory(dirPath).list(followLinks: false)) {
        final name = p.basename(ent.path);
        if (ent is! Directory || _isIgnored(name)) continue;
        out.add(MediaEntry(
          path: ent.path,
          type: EntryType.folder,
          modified: DateTime.fromMillisecondsSinceEpoch(0),
        ));
      }
    } catch (_) {}
    out.sort((a, b) => _naturalCompare(a.name, b.name));
    return out;
  }

  /// Summary for [dirPath] if it's already known without any I/O (always on
  /// Android once the index is built; on other platforms once computed).
  FolderSummary? cachedSummary(String dirPath) {
    if (summarizeOverride != null) return summarizeOverride!(dirPath);
    if (usesIndex(dirPath)) {
      return MediaStoreIndex.instance.isBuilt
          ? MediaStoreIndex.instance.summaryOf(dirPath)
          : null;
    }
    return _summaryCache[dirPath];
  }

  /// Lists a single directory (non-recursive), separating folders and media.
  Future<DirectoryListing> scan(String dirPath) async {
    if (scanOverride != null) return scanOverride!(dirPath);
    // On Android browsing is always backed by the MediaStore index — USB media
    // isn't reachable via dart:io under scoped storage, and listing real paths
    // like '/' throws a PathAccessException. Folders come from the in-memory
    // tree; the folder's media is queried from MediaStore on demand.
    if (usesIndex(dirPath)) {
      final index = MediaStoreIndex.instance;
      final media = await index.mediaOf(dirPath);
      return DirectoryListing(
          path: dirPath, entries: [...index.foldersOf(dirPath), ...media]);
    }
    if (Platform.isAndroid) {
      // Direct drive access: listed natively, with MediaStore data merged in.
      final entries = await AndroidFiles.listDir(dirPath)
        ..sort(_folderThenName);
      return DirectoryListing(path: dirPath, entries: entries);
    }
    final dir = Directory(dirPath);
    final entries = <MediaEntry>[];
    if (!await dir.exists()) {
      return DirectoryListing(path: dirPath, entries: entries);
    }

    await for (final ent in dir.list(followLinks: false)) {
      final name = p.basename(ent.path);
      if (_isIgnored(name)) continue;
      try {
        // The listing already knows each entry's type; only stat media files
        // (for date/size) — never folders or unrelated files.
        if (ent is Directory) {
          entries.add(MediaEntry(
            path: ent.path,
            type: EntryType.folder,
            modified: DateTime.fromMillisecondsSinceEpoch(0),
          ));
        } else if (ent is File) {
          final kind = _classify(name);
          if (kind == null) continue;
          final stat = await ent.stat();
          entries.add(MediaEntry(
            path: ent.path,
            type: kind,
            modified: stat.modified,
            size: stat.size,
          ));
        }
      } catch (_) {
        // Unreadable entry — skip it.
      }
    }

    entries.sort(_folderThenName);

    return DirectoryListing(path: dirPath, entries: entries);
  }

  /// Recursively counts media and finds a cover image for a folder card.
  /// Results are memoized per path for the session. Null if the walk was
  /// stopped with [cancelSummarize].
  Future<FolderSummary?> summarize(String dirPath) async {
    if (summarizeOverride != null) return summarizeOverride!(dirPath);
    if (usesIndex(dirPath)) {
      return MediaStoreIndex.instance.summaryOf(dirPath);
    }
    final cached = _summaryCache[dirPath];
    if (cached != null && _fresh.contains(dirPath)) return cached;
    // A folder card and the browser can ask for the same folder at once —
    // share one walk instead of running it twice.
    return _summaryInflight[dirPath] ??= (Platform.isAndroid
            ? _androidSummary(dirPath)
            : _walkSummary(dirPath))
        .whenComplete(() {
      _summaryInflight.remove(dirPath);
      _summaryIds.remove(dirPath);
    });
  }

  Future<FolderSummary?> _androidSummary(String dirPath) async {
    final id = _summaryIds[dirPath] = _nextSummaryId++;
    final s = await AndroidFiles.summary(dirPath, id: id);
    if (s != null) _remember(dirPath, s);
    return s;
  }

  /// Stops an in-progress summary walk (its screen was covered); a later
  /// [summarize] starts it again.
  void cancelSummarize(String dirPath) {
    final id = _summaryIds.remove(dirPath);
    if (id != null) unawaited(AndroidFiles.cancelSummary(id));
  }

  Future<FolderSummary> _walkSummary(String dirPath) async {
    int mediaCount = 0;
    int subfolderCount = 0;
    String? coverPath;
    bool coverIsVideo = false;
    String? firstVideo;
    DateTime coverMod = DateTime.fromMillisecondsSinceEpoch(0);

    Future<void> walk(String path, {required bool topLevel}) async {
      final dir = Directory(path);
      List<FileSystemEntity> children;
      try {
        children = await dir.list(followLinks: false).toList();
      } catch (_) {
        return;
      }
      for (final ent in children) {
        final name = p.basename(ent.path);
        if (_isIgnored(name)) continue;
        // No stat needed: the listing already reports each entry's type.
        if (ent is Directory) {
          if (topLevel) subfolderCount++;
          await walk(ent.path, topLevel: false);
        } else if (ent is File) {
          final kind = _classify(name);
          if (kind == EntryType.image) {
            mediaCount++;
            coverPath ??= ent.path; // prefer a still image as the cover
          } else if (kind == EntryType.video) {
            mediaCount++;
            firstVideo ??= ent.path;
          }
        }
      }
    }

    await walk(dirPath, topLevel: true);

    if (coverPath == null && firstVideo != null) {
      coverPath = firstVideo;
      coverIsVideo = true;
    }

    final cp = coverPath;
    DateTime? date;
    if (cp != null) {
      try {
        date = (await File(cp).stat()).modified; // one stat for date sorting
      } catch (_) {}
    }
    final summary = FolderSummary(
      mediaCount: mediaCount,
      subfolderCount: subfolderCount,
      date: date,
      cover: cp == null
          ? null
          : MediaEntry(
              path: cp,
              type: coverIsVideo ? EntryType.video : EntryType.image,
              modified: coverMod,
            ),
    );
    _remember(dirPath, summary);
    return summary;
  }

  /// Forgets cached summaries for [dirPath] (and inside it) after it was
  /// renamed or deleted, and marks its ancestors stale so their counts are
  /// redone the next time they're shown.
  void forget(String dirPath) {
    _summaryCache.removeWhere((k, _) => k == dirPath || k.startsWith('$dirPath/'));
    _fresh.removeWhere((k) => k == dirPath || k.startsWith('$dirPath/'));
    var parent = p.dirname(dirPath);
    while (true) {
      _fresh.remove(parent);
      final up = p.dirname(parent);
      if (up == parent) break;
      parent = up;
    }
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 2), _save);
  }

  /// Whether [dirPath]'s summary is up to date for this session (vs. saved
  /// from a previous one and still to be refreshed).
  bool isFresh(String dirPath) =>
      summarizeOverride != null ||
      usesIndex(dirPath) ||
      _fresh.contains(dirPath);

  void _remember(String dirPath, FolderSummary s) {
    _summaryCache[dirPath] = s;
    _fresh.add(dirPath);
    // Coalesce the burst of walks a folder page triggers into one write.
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 2), _save);
  }

  /// Loads the folder summaries saved by previous sessions, so folder cards
  /// show their counts and covers instantly (then refresh in the background).
  Future<void> loadSaved() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final store = _store = File(p.join(dir.path, 'folder_summaries_v1.json'));
      if (!await store.exists()) return;
      final saved = jsonDecode(await store.readAsString()) as Map<String, dynamic>;
      final epoch = DateTime.fromMillisecondsSinceEpoch(0);
      saved.forEach((path, v) {
        final r = v as List<dynamic>;
        final cover = r[2] as String?;
        final dateMs = r.length > 4 ? r[4] as int? : null;
        _summaryCache.putIfAbsent(
          path,
          () => FolderSummary(
            mediaCount: r[0] as int,
            subfolderCount: r[1] as int,
            date: dateMs == null
                ? null
                : DateTime.fromMillisecondsSinceEpoch(dateMs),
            cover: cover == null
                ? null
                : MediaEntry(
                    path: cover,
                    type: (r[3] as bool) ? EntryType.video : EntryType.image,
                    modified: epoch,
                  ),
          ),
        );
      });
    } catch (_) {
      // Unreadable / old format — start fresh.
    }
  }

  Future<void> _save() async {
    final store = _store;
    if (store == null) return;
    try {
      await store.writeAsString(jsonEncode({
        for (final e in _summaryCache.entries)
          e.key: [
            e.value.mediaCount,
            e.value.subfolderCount,
            e.value.cover?.path,
            e.value.cover?.isVideo ?? false,
            e.value.date?.millisecondsSinceEpoch,
          ],
      }));
    } catch (_) {}
  }

  /// Folders first, then media; each group sorted by name (natural-ish).
  int _folderThenName(MediaEntry a, MediaEntry b) {
    if (a.isFolder != b.isFolder) return a.isFolder ? -1 : 1;
    return _naturalCompare(a.name, b.name);
  }

  /// Compares names so that `IMG_2` sorts before `IMG_10`.
  int _naturalCompare(String a, String b) {
    final ra = RegExp(r'(\d+|\D+)').allMatches(a.toLowerCase());
    final rb = RegExp(r'(\d+|\D+)').allMatches(b.toLowerCase());
    final ia = ra.iterator;
    final ib = rb.iterator;
    while (ia.moveNext() && ib.moveNext()) {
      final sa = ia.current.group(0)!;
      final sb = ib.current.group(0)!;
      final na = int.tryParse(sa);
      final nb = int.tryParse(sb);
      int c;
      if (na != null && nb != null) {
        c = na.compareTo(nb);
      } else {
        c = sa.compareTo(sb);
      }
      if (c != 0) return c;
    }
    return a.length.compareTo(b.length);
  }
}
