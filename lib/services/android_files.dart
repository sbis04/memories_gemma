import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';

import '../models/media_entry.dart';

/// Direct drive access on Android via "All files access"
/// (MANAGE_EXTERNAL_STORAGE), backed by MediaIndexChannel.kt.
///
/// Reading a USB drive's directories directly is complete and instant, unlike
/// Android's MediaStore, which can take a very long time to index a large
/// drive (only the folders it has reached would show). MediaStore is still
/// used to enrich files it has already indexed (fast system thumbnails, capture
/// date, GPS); the rest get native thumbnails and header-only sizes.
class AndroidFiles {
  AndroidFiles._();

  static const _channel = MethodChannel('tv_gallery/media_index');

  static bool _granted = false;

  /// Whether the app may read drives directly. Resolved once at startup
  /// ([init]); when false, browsing falls back to the MediaStore index.
  static bool get granted => _granted;

  static Future<void> init() async {
    if (!Platform.isAndroid) return;
    try {
      _granted = await Permission.manageExternalStorage.isGranted;
    } catch (_) {
      _granted = false;
    }
  }

  /// Real (direct-access) paths live under /storage; everything else on
  /// Android is a virtual MediaStore-index path.
  static bool isRealPath(String path) => path.startsWith('/storage/');

  /// Mounted volumes, USB drives first: (path, description, isRemovable).
  static Future<List<(String, String, bool)>> volumes() async {
    final rows = await _channel.invokeListMethod<List<Object?>>('volumes');
    return [
      for (final r in rows ?? const <List<Object?>>[])
        (r[0] as String, r[1] as String, r[2] as bool),
    ];
  }

  /// Lists a real directory: subfolders and media (with MediaStore data merged
  /// in for files Android has already indexed).
  static Future<List<MediaEntry>> listDir(String dirPath) async {
    final res = await _channel
        .invokeMapMethod<String, Object?>('listDir', {'path': dirPath});
    final epoch = DateTime.fromMillisecondsSinceEpoch(0);
    final entries = <MediaEntry>[
      for (final name in (res?['dirs'] as List?) ?? const [])
        MediaEntry(
          path: p.join(dirPath, name as String),
          type: EntryType.folder,
          modified: epoch,
        ),
    ];
    for (final raw in (res?['files'] as List?) ?? const []) {
      final r = raw as List<Object?>;
      final w = r[4] as int;
      final h = r[5] as int;
      entries.add(MediaEntry(
        path: p.join(dirPath, r[0] as String),
        type: (r[1] as bool) ? EntryType.video : EntryType.image,
        modified: DateTime.fromMillisecondsSinceEpoch(r[2] as int),
        size: r[3] as int,
        assetId: r[6] as String?,
        pxWidth: w > 0 ? w : null,
        pxHeight: h > 0 ? h : null,
      ));
    }
    return entries;
  }

  /// Subfolders of a real directory (names only; no media listing).
  static Future<List<MediaEntry>> dirs(String dirPath) async {
    final names =
        await _channel.invokeListMethod<String>('dirs', {'path': dirPath});
    final epoch = DateTime.fromMillisecondsSinceEpoch(0);
    return [
      for (final n in names ?? const <String>[])
        MediaEntry(path: p.join(dirPath, n), type: EntryType.folder, modified: epoch),
    ];
  }

  /// Recursive media count, subfolder count and cover for a folder card;
  /// null if cancelled with [cancelSummary].
  static Future<FolderSummary?> summary(String dirPath, {int id = -1}) async {
    final r = await _channel
        .invokeListMethod<Object?>('summary', {'path': dirPath, 'id': id});
    if (r == null) return null;
    final cover = r[2] as String?;
    final dateMs = r.length > 4 ? r[4] as int? : null;
    return FolderSummary(
      mediaCount: r[0] as int,
      subfolderCount: r[1] as int,
      date: dateMs == null ? null : DateTime.fromMillisecondsSinceEpoch(dateMs),
      cover: cover == null
          ? null
          : MediaEntry(
              path: cover,
              type: (r[3] as bool) ? EntryType.video : EntryType.image,
              modified: DateTime.fromMillisecondsSinceEpoch(0),
            ),
    );
  }

  static Future<void> cancelSummary(int id) async {
    try {
      await _channel.invokeMethod<void>('cancelSummary', {'id': id});
    } catch (_) {}
  }

  /// Displayed pixel sizes of images from their headers: (w, h), (0, 0) when
  /// unknown.
  static Future<List<(int, int)>> sizes(List<String> paths) async {
    final rows = await _channel
        .invokeListMethod<List<Object?>>('sizes', {'paths': paths});
    return [
      for (final r in rows ?? const <List<Object?>>[]) (r[0] as int, r[1] as int),
    ];
  }

  /// Writes a JPEG thumbnail of [path] to [dst] with the platform thumbnailer.
  /// [id] lets an in-flight request be stopped with [cancelThumb].
  static Future<bool> thumb(String path, String dst,
      {required int maxDim,
      required int quality,
      required bool isVideo,
      int id = -1}) async {
    try {
      return await _channel.invokeMethod<bool>('thumb', {
            'path': path,
            'dst': dst,
            'maxDim': maxDim,
            'quality': quality,
            'isVideo': isVideo,
            'id': id,
          }) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Cancels the thumbnail request started with [id] (queued or decoding).
  static Future<void> cancelThumb(int id) async {
    try {
      await _channel.invokeMethod<void>('cancelThumb', {'id': id});
    } catch (_) {}
  }
}
