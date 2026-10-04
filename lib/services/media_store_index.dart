import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';

import '../models/media_entry.dart';

/// Builds an in-memory folder tree from Android's MediaStore so the
/// filesystem-style browser works on Android — including media on USB drives,
/// which raw `dart:io` access can't reach under scoped storage. Virtual paths
/// are posix with a leading slash (root is "/").
///
/// The tree is built from a per-folder summary (count + cover) computed natively
/// in one cursor pass (see MediaIndexChannel.kt) — never a per-file listing — so
/// folders appear almost instantly even for drives with tens of thousands of
/// files. The last tree is also persisted, so on launch folders show before the
/// MediaStore has even been queried. A folder's media is fetched only when it's
/// opened ([mediaOf]).
///
/// Android indexes a freshly-plugged USB drive progressively (can take minutes
/// for thousands of files), so this listens for MediaStore changes and refreshes
/// the tree, notifying listeners (the browser refreshes) as new media appears.
class MediaStoreIndex extends ChangeNotifier {
  MediaStoreIndex._();
  static final MediaStoreIndex instance = MediaStoreIndex._();

  static const _channel = MethodChannel('tv_gallery/media_index');

  /// Asset handles for photo_manager (thumbnails, origin files, GPS), keyed by
  /// MediaStore id. Populated for covers and for media of opened folders.
  final Map<String, AssetEntity> _assets = {};

  /// Virtual folder path -> immediate subfolder paths.
  final Map<String, Set<String>> _subfolders = {};

  /// Virtual folder path -> raw MediaStore folder keys (RELATIVE_PATH values)
  /// whose media live directly in it.
  final Map<String, Set<String>> _keys = {};

  /// Virtual folder path -> direct media count and newest cover.
  final Map<String, (int, MediaEntry?)> _direct = {};

  final Map<String, FolderSummary> _summaries = {};
  final Map<String, Future<List<MediaEntry>>> _media = {};

  List<Object?>? _lastRows;
  Future<bool>? _building;
  bool _built = false;
  bool _watching = false;
  bool _refreshing = false;
  bool _refreshAgain = false;
  bool _scanning = false;
  Timer? _debounce;
  Timer? _settle;

  bool get isBuilt => _built;

  /// True while Android is still actively indexing media (e.g. a freshly
  /// plugged-in USB drive): change events are still arriving and the counts are
  /// climbing. Flips back to false once things have been quiet for a few
  /// seconds. The browser uses this to show a subtle "still loading" indicator.
  bool get isScanning => _scanning;
  AssetEntity? asset(String? id) => id == null ? null : _assets[id];

  /// The photo_manager handle for [entry]'s MediaStore id, created on demand —
  /// entries read straight from a drive carry an id without ever having gone
  /// through this index.
  AssetEntity? assetFor(MediaEntry entry) {
    final id = entry.assetId;
    if (id == null) return null;
    _registerAsset(
        id, entry.isVideo, entry.pxWidth ?? 0, entry.pxHeight ?? 0);
    return _assets[id];
  }

  /// Immediate subfolders of [path], sorted by name. Synchronous — the tree is
  /// always in memory once built.
  List<MediaEntry> foldersOf(String path) {
    final epoch = DateTime.fromMillisecondsSinceEpoch(0);
    final subs = (_subfolders[path] ?? const <String>{}).toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return [
      for (final s in subs)
        MediaEntry(path: s, type: EntryType.folder, modified: epoch),
    ];
  }

  FolderSummary summaryOf(String path) =>
      _summaries[path] ??= _summarize(path);

  /// Media directly inside [path], fetched from MediaStore on first request and
  /// memoized until the library changes.
  Future<List<MediaEntry>> mediaOf(String path) {
    final keys = _keys[path];
    if (keys == null || keys.isEmpty) return Future.value(const []);
    return _media[path] ??= _fetchMedia(path, keys.toList()).catchError((_) {
      _media.remove(path); // don't memoize a failure
      return const <MediaEntry>[];
    });
  }

  Future<List<MediaEntry>> _fetchMedia(String path, List<String> keys) async {
    final rows =
        await _channel.invokeListMethod<List<Object?>>('list', {'keys': keys});
    final out = <MediaEntry>[];
    for (final r in rows ?? const <List<Object?>>[]) {
      final id = r[0] as String;
      final name = r[1] as String;
      final isVideo = r[2] as bool;
      final w = r[4] as int;
      final h = r[5] as int;
      out.add(MediaEntry(
        path: path == '/' ? '/$name' : '$path/$name',
        type: isVideo ? EntryType.video : EntryType.image,
        modified: DateTime.fromMillisecondsSinceEpoch(r[3] as int),
        assetId: id,
        pxWidth: w,
        pxHeight: h,
      ));
      _registerAsset(id, isVideo, w, h);
    }
    return out;
  }

  void _registerAsset(String id, bool isVideo, int w, int h) {
    _assets[id] ??=
        AssetEntity(id: id, typeInt: isVideo ? 2 : 1, width: w, height: h);
  }

  /// Requests media permission and builds the tree (from the on-disk cache
  /// first, if there is one), then starts watching for MediaStore changes.
  /// Returns false if permission was denied. Safe to call repeatedly.
  Future<bool> build() => _building ??= _build().then((ok) {
        if (!ok) _building = null; // allow a retry after granting permission
        return ok;
      });

  Future<bool> _build() async {
    final ps = await PhotoManager.requestPermissionExtend();
    if (!ps.hasAccess) return false;
    final cached = await _readCache();
    if (cached != null) {
      _apply(cached);
      // Folders are on screen; reconcile with the live MediaStore behind them.
      unawaited(_refresh());
    } else {
      await _refresh();
    }
    _startWatching();
    return true;
  }

  void _startWatching() {
    if (_watching) return;
    _watching = true;
    PhotoManager.addChangeCallback(_onLibraryChanged);
    // ignore: discarded_futures
    PhotoManager.startChangeNotify();
  }

  void _onLibraryChanged(MethodCall _) {
    _markScanning();
    // Coalesce the burst of change events Android emits while scanning a USB
    // drive into a single refresh.
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 1500), () {
      // ignore: discarded_futures
      _refresh();
    });
  }

  /// Marks the index as actively scanning and (re)arms a "settle" timer; once
  /// no change events have arrived for a few seconds, scanning flips off.
  void _markScanning() {
    _settle?.cancel();
    if (!_scanning) {
      _scanning = true;
      notifyListeners();
    }
    _settle = Timer(const Duration(seconds: 5), () {
      _scanning = false;
      notifyListeners();
    });
  }

  Future<void> _refresh() async {
    if (_refreshing) {
      _refreshAgain = true;
      return;
    }
    _refreshing = true;
    try {
      final rows = await _channel.invokeListMethod<Object?>('folders');
      if (rows != null) {
        _apply(rows);
        unawaited(_writeCache(rows));
      }
    } catch (_) {
      // Leave the previous index in place on error.
    } finally {
      _refreshing = false;
      if (_refreshAgain) {
        _refreshAgain = false;
        unawaited(_refresh());
      }
    }
  }

  /// Rebuilds the tree from native folder rows
  /// (`[key, count, coverId, coverIsVideo, coverW, coverH]`).
  void _apply(List<Object?> rows) {
    // Nothing changed since last time — skip the work and the UI refresh.
    if (_built && listEquals(_flatten(rows), _flatten(_lastRows))) return;
    _lastRows = rows;

    _subfolders
      ..clear()
      ..['/'] = {};
    _keys.clear();
    _direct.clear();
    _summaries.clear();
    _media.clear();

    void ensureFolder(String folderPath) {
      if (folderPath == '/') return;
      final parent = p.posix.dirname(folderPath);
      final siblings = _subfolders[parent] ??= {};
      if (siblings.add(folderPath)) ensureFolder(parent);
      _subfolders[folderPath] ??= {};
    }

    final epoch = DateTime.fromMillisecondsSinceEpoch(0);
    for (final raw in rows) {
      final r = raw as List<Object?>;
      final key = r[0] as String;
      final rel = key.replaceAll(RegExp(r'^/+|/+$'), '');
      final folderPath = rel.isEmpty ? '/' : '/$rel';
      ensureFolder(folderPath);
      (_keys[folderPath] ??= {}).add(key);

      final coverId = r[2] as String;
      final coverIsVideo = r[3] as bool;
      final w = r[4] as int;
      final h = r[5] as int;
      _registerAsset(coverId, coverIsVideo, w, h);
      final cover = MediaEntry(
        path: '$folderPath/$coverId',
        type: coverIsVideo ? EntryType.video : EntryType.image,
        modified: epoch,
        assetId: coverId,
        pxWidth: w,
        pxHeight: h,
      );
      final prev = _direct[folderPath];
      // Same folder on two volumes: add counts, prefer a still-image cover.
      final keepPrev = prev?.$2 != null && (prev!.$2!.isImage || coverIsVideo);
      _direct[folderPath] =
          ((prev?.$1 ?? 0) + (r[1] as int), keepPrev ? prev.$2 : cover);
    }

    _built = true;
    notifyListeners();
  }

  static List<Object?> _flatten(List<Object?>? rows) => [
        for (final r in rows ?? const <Object?>[]) ...(r as List<Object?>),
      ];

  FolderSummary _summarize(String path) {
    final direct = _direct[path];
    var media = direct?.$1 ?? 0;
    MediaEntry? cover = direct?.$2;
    final subs = _subfolders[path] ?? const <String>{};
    for (final s in subs) {
      final sub = summaryOf(s);
      media += sub.mediaCount;
      // Prefer a still image anywhere in the subtree over a video cover.
      if (cover == null || (cover.isVideo && sub.cover?.isImage == true)) {
        cover = sub.cover ?? cover;
      }
    }
    return FolderSummary(
      mediaCount: media,
      subfolderCount: subs.length,
      cover: cover,
    );
  }

  Future<File> _cacheFile() async {
    final dir = await getApplicationSupportDirectory();
    return File(p.join(dir.path, 'media_index_v1.json'));
  }

  Future<List<Object?>?> _readCache() async {
    try {
      final f = await _cacheFile();
      if (!await f.exists()) return null;
      return jsonDecode(await f.readAsString()) as List<Object?>;
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeCache(List<Object?> rows) async {
    try {
      await (await _cacheFile()).writeAsString(jsonEncode(rows), flush: true);
    } catch (_) {}
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _settle?.cancel();
    if (_watching) PhotoManager.removeChangeCallback(_onLibraryChanged);
    super.dispose();
  }
}
