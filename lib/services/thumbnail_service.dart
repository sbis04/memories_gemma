import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:fc_native_video_thumbnail/fc_native_video_thumbnail.dart';
import 'package:photo_manager/photo_manager.dart';

import '../models/media_entry.dart';
import 'android_files.dart';
import 'media_store_index.dart';

/// Generates displayable thumbnails / full images and resolves dimensions,
/// caching everything on disk so the expensive work happens at most once per
/// file.
///
/// Two backends:
/// - **macOS** (dev): shells out to the built-in `sips` (HEIC→JPEG) and
///   `qlmanage` (video posters).
/// - **Android / iOS** (deployment): decodes images with the platform codec
///   (HEIC is native), downscaling via Flutter, and extracts video posters
///   with the `video_thumbnail` plugin.
class ThumbnailService {
  ThumbnailService._();
  static final ThumbnailService instance = ThumbnailService._();

  Directory? _cacheDir;
  final Map<String, Future<File?>> _inflight = {};
  final Map<String, Size> _dimCache = {};
  // On Android the native side decodes 3 at a time; keeping no more than
  // that in flight means "what next?" is always decided here, by priority.
  late final _Pool _pool =
      _Pool(Platform.isAndroid ? 3 : 4, paused: () => _videosPlaying.isNotEmpty);

  // Videos currently playing. HEIC photos decode on the same hardware (HEVC)
  // decoder as most videos, and every decode costs CPU — so while a video
  // plays, queued image work waits instead of making playback stutter.
  final Set<Object> _videosPlaying = {};

  /// Called by the video backends as playback starts/stops (or ends).
  void setVideoPlaying(Object player, bool playing) {
    final changed =
        playing ? _videosPlaying.add(player) : _videosPlaying.remove(player);
    if (changed && _videosPlaying.isEmpty) _pool.resume();
  }

  bool get videoPlaying => _videosPlaying.isNotEmpty;
  int _nextThumbId = 0;

  // Header-size lookups for not-yet-indexed Android files, batched into one
  // native call per frame (a gallery asks for every item at once).
  final Map<String, Completer<Size?>> _sizeWaiters = {};
  Timer? _sizeFlush;

  /// Test seams: when set, these bypass the on-disk / process pipeline so
  /// widget & golden tests can render deterministically without `sips`.
  Future<File?> Function(MediaEntry entry, int maxDim)? thumbnailOverride;
  Future<File?> Function(MediaEntry entry)? fullImageOverride;
  Future<Size?> Function(MediaEntry entry)? dimensionsOverride;

  bool get _isMacOS => Platform.isMacOS;

  Future<Directory> _ensureCacheDir() async {
    if (_cacheDir != null) return _cacheDir!;
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'thumb_cache'));
    if (!await dir.exists()) await dir.create(recursive: true);
    _cacheDir = dir;
    return dir;
  }

  /// Stable 64-bit FNV-1a hash, hex-encoded — used for cache filenames so the
  /// same source always maps to the same cache entry across launches.
  String _key(String input) {
    var hash = 0xcbf29ce484222325;
    const mask = 0xFFFFFFFFFFFFFFFF;
    for (final c in input.codeUnits) {
      hash = (hash ^ c) & mask;
      hash = (hash * 0x100000001b3) & mask;
    }
    return hash.toRadixString(16).padLeft(16, '0');
  }

  /// Returns a displayable image file for a thumbnail of [entry] at roughly
  /// [maxDim] px on its longest side. Returns null on failure.
  Future<File?> thumbnail(MediaEntry entry,
      {int maxDim = 480,
      int quality = 95,
      bool Function()? wanted,
      double Function()? priority,
      ThumbCancel? cancel,
      bool urgent = false}) {
    if (thumbnailOverride != null) return thumbnailOverride!(entry, maxDim);
    if (entry.assetId != null) {
      final tag = 'ms|${entry.assetId}|$maxDim|q$quality';
      // When a cancel token is supplied (a scrolling grid tile) skip the dedup
      // cache so each tile owns its request and can bail out independently when
      // it scrolls off-screen.
      if (wanted != null) {
        return _mediaStoreThumb(entry, maxDim, quality, tag, wanted, priority);
      }
      return _dedup(tag,
          () => _mediaStoreThumb(entry, maxDim, quality, tag, null, null, urgent));
    }
    final cacheKey =
        '${entry.path}|${entry.size}|${entry.modified.millisecondsSinceEpoch}'
        '|${entry.type}|t$maxDim';
    // As above: a grid tile owns its request so it can be skipped once the
    // tile has scrolled away.
    if (wanted != null) {
      return _buildThumbnail(entry, maxDim, cacheKey, wanted, priority, cancel);
    }
    return _dedup(cacheKey,
        () => _buildThumbnail(entry, maxDim, cacheKey, null, null, null, urgent));
  }

  /// Android MediaStore thumbnail (works for assets on USB drives too).
  Future<File?> _mediaStoreThumb(MediaEntry entry, int maxDim, int quality,
      String tag, bool Function()? wanted,
      [double Function()? priority, bool urgent = false]) async {
    final asset = MediaStoreIndex.instance.assetFor(entry);
    if (asset == null) return null;
    final cacheDir = await _ensureCacheDir();
    final out = File(p.join(cacheDir.path, '${_key(tag)}.jpg'));
    if (await out.exists() && await out.length() > 0) {
      _touch(out);
      return out;
    }
    // Throttle through the pool so a burst (scrolling, or the viewer) never
    // floods the hardware decoder.
    final bytes = await _pool.run(() {
      // By the time our turn comes, the requesting tile may have scrolled away
      // — skip the decode entirely so visible tiles aren't held up behind it.
      if (wanted != null && !wanted()) return Future<Uint8List?>.value(null);
      return asset.thumbnailDataWithSize(
        ThumbnailSize(maxDim, maxDim),
        quality: quality,
      );
    }, priority: priority, urgent: urgent);
    if (bytes == null) return null;
    await out.writeAsBytes(bytes, flush: true);
    return out;
  }

  /// A real, readable file for [entry] for full-screen display or video
  /// playback. For MediaStore assets this materialises the origin file.
  Future<File?> originFile(MediaEntry entry) {
    // A real path (desktop, or an Android drive read directly) is the file.
    if (!Platform.isAndroid || AndroidFiles.isRealPath(entry.path)) {
      return Future.value(File(entry.path));
    }
    if (entry.assetId != null) {
      final a = MediaStoreIndex.instance.assetFor(entry);
      return a == null ? Future.value(null) : a.file;
    }
    return Future.value(File(entry.path));
  }

  /// Warms the cache for a whole folder in the background so scrolling finds
  /// thumbnails ready and revisits are instant. Requests are deduped and
  /// throttled by the worker pool; enqueued in display order so the first
  /// (visible) rows are generated first. Fire-and-forget.
  void prefetch(Iterable<MediaEntry> entries, {int maxDim = 640}) {
    if (thumbnailOverride != null) return;
    // Only warm the whole folder on macOS (one-time `sips` cost). On Android
    // each thumbnail needs the single hardware HEVC decoder; warming hundreds
    // would saturate it and starve on-demand requests (e.g. opening a photo),
    // and the OS caches MediaStore thumbnails anyway.
    if (!Platform.isMacOS) return;
    for (final e in entries) {
      if (!e.isFolder) {
        // ignore: discarded_futures
        thumbnail(e, maxDim: maxDim);
      }
    }
  }

  /// Returns a full-resolution displayable image for [entry]. For HEIC this is
  /// a converted JPEG; for natively-supported formats it's the original file.
  /// [quality] (1–100) lets callers trade a little fidelity for speed — the
  /// viewer uses 100 (the image the user opened), the slideshow a touch lower
  /// so slides decode/load faster.
  Future<File?> fullImage(MediaEntry entry, {int quality = 100}) {
    if (fullImageOverride != null) return fullImageOverride!(entry);
    if (entry.assetId != null || Platform.isAndroid) {
      // Decoding a 12–48MP HEIC off USB is slow and memory-heavy on a TV — show
      // a large screen-sized image instead (plenty for a 4K display).
      return thumbnail(entry, maxDim: 2560, quality: quality);
    }
    if (!entry.isImage) return Future.value(null);
    final ext = p.extension(entry.name).toLowerCase();
    final nativelySupported =
        {'.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp'}.contains(ext);
    if (nativelySupported || !_isMacOS) {
      return Future.value(File(entry.path));
    }
    final cacheKey = '${entry.path}|${entry.size}'
        '|${entry.modified.millisecondsSinceEpoch}|full';
    return _dedup(cacheKey, () => _buildFull(entry, cacheKey));
  }

  Future<File?> _dedup(String key, Future<File?> Function() build) {
    final existing = _inflight[key];
    if (existing != null) return existing;
    final future = build();
    _inflight[key] = future;
    future.whenComplete(() => _inflight.remove(key));
    return future;
  }

  Future<File?> _buildThumbnail(MediaEntry entry, int maxDim, String cacheKey,
      [bool Function()? wanted,
      double Function()? priority,
      ThumbCancel? cancel,
      bool urgent = false]) async {
    final cacheDir = await _ensureCacheDir();
    final out = File(p.join(cacheDir.path, '${_key(cacheKey)}.jpg'));
    if (await out.exists() && await out.length() > 0) {
      _touch(out);
      return out;
    }

    if (Platform.isAndroid) {
      // Platform thumbnailer: embedded EXIF thumbnails / sampled hardware
      // decode with rotation applied — much cheaper than a full decode.
      final ok = await _pool.run(() async {
        // Skip tiles that scrolled off-screen while queued (see above).
        if ((wanted != null && !wanted()) || (cancel?.cancelled ?? false)) {
          return false;
        }
        // ...and stop a decode that's already running if the tile goes away.
        final id = _nextThumbId++;
        cancel?._onCancel = () => AndroidFiles.cancelThumb(id);
        try {
          return await AndroidFiles.thumb(entry.path, out.path,
              maxDim: maxDim, quality: 85, isVideo: entry.isVideo, id: id);
        } finally {
          cancel?._onCancel = null;
        }
      }, priority: priority, urgent: urgent);
      return ok ? out : null;
    }
    if (entry.isImage) {
      final ok = _isMacOS
          ? await _pool.run(() => _sipsResize(entry.path, out.path, maxDim))
          : await _pool.run(() => _decodeResize(entry.path, out.path, maxDim));
      return ok ? out : null;
    } else {
      // Video poster frame.
      final ok = _isMacOS
          ? await _pool.run(() => _qlThumb(entry.path, out.path, maxDim))
          : await _pool.run(() => _videoThumb(entry.path, out.path, maxDim));
      return ok ? out : null;
    }
  }

  Future<File?> _buildFull(MediaEntry entry, String cacheKey) async {
    final cacheDir = await _ensureCacheDir();
    final out = File(p.join(cacheDir.path, '${_key(cacheKey)}.jpg'));
    if (await out.exists() && await out.length() > 0) return out;
    final ok = await _pool.run(() => _sipsResize(entry.path, out.path, 0));
    return ok ? out : null;
  }

  /// Marks a cache file as recently used (best-effort) so it survives LRU
  /// eviction longer.
  void _touch(File f) {
    try {
      f.setLastModifiedSync(DateTime.now());
    } catch (_) {}
  }

  /// Caps the on-disk cache at [maxBytes], deleting least-recently-used entries
  /// first. Safe to call at startup; runs off the worker pool.
  Future<void> trimCache({int maxBytes = 700 * 1024 * 1024}) async {
    try {
      final dir = await _ensureCacheDir();
      final files = await dir
          .list()
          .where((e) => e is File)
          .cast<File>()
          .toList();
      var total = 0;
      final stats = <(File, FileStat)>[];
      for (final f in files) {
        final st = await f.stat();
        total += st.size;
        stats.add((f, st));
      }
      if (total <= maxBytes) return;
      stats.sort((a, b) => a.$2.modified.compareTo(b.$2.modified)); // oldest first
      for (final (file, st) in stats) {
        if (total <= maxBytes) break;
        try {
          await file.delete();
          total -= st.size;
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// Resolves the pixel dimensions of [entry], used to lay out the justified
  /// gallery. Cached in memory.
  Future<Size?> dimensions(MediaEntry entry) async {
    if (dimensionsOverride != null) return dimensionsOverride!(entry);
    if (entry.pxWidth != null &&
        entry.pxHeight != null &&
        entry.pxWidth! > 0 &&
        entry.pxHeight! > 0) {
      return Size(entry.pxWidth!.toDouble(), entry.pxHeight!.toDouble());
    }
    final cached = _dimCache[entry.path];
    if (cached != null) return cached;
    Size? size;
    if (Platform.isAndroid) {
      // Not indexed by MediaStore yet. Read image headers natively (never the
      // whole file); assume 16:9 for videos rather than extracting a frame.
      size = entry.isVideo
          ? const Size(16, 9)
          : await _nativeSize(entry.path) ?? const Size(4, 3);
    } else if (_isMacOS) {
      // Derive the aspect ratio from the generated thumbnail's header rather
      // than spawning a separate `sips` process per image — this is the same
      // thumbnail the tile displays, so one conversion serves both and the
      // worker pool isn't flooded with hundreds of dimension probes.
      final thumb = await thumbnail(entry, maxDim: 640);
      if (thumb != null) size = await _readImageDimensions(thumb);
    } else if (entry.isImage) {
      // Android/iOS: ImageDescriptor reports the source size for any format the
      // platform decodes (incl. HEIC) without decoding the pixels.
      size = await _descriptorDimensions(File(entry.path)) ??
          await _readImageDimensions(File(entry.path));
    } else {
      // Video: read dimensions off the generated poster.
      final thumb = await thumbnail(entry, maxDim: 640);
      if (thumb != null) {
        size = await _descriptorDimensions(thumb) ??
            await _readImageDimensions(thumb);
      }
    }
    if (size != null) _dimCache[entry.path] = size;
    return size;
  }

  Future<Size?> _nativeSize(String path) {
    final c = _sizeWaiters.putIfAbsent(path, Completer<Size?>.new);
    _sizeFlush ??= Timer(Duration.zero, _flushSizes);
    return c.future;
  }

  /// Drops queued header-size reads (e.g. the gallery that asked was closed)
  /// so they don't compete for the drive with whatever is on screen now.
  void cancelPendingSizes() {
    for (final c in _sizeWaiters.values) {
      if (!c.isCompleted) c.complete(null);
    }
    _sizeWaiters.clear();
  }

  /// Resolves queued header sizes in display order, a chunk at a time, so the
  /// first rows of a large folder settle first. New requests (and
  /// [cancelPendingSizes]) are seen between chunks.
  Future<void> _flushSizes() async {
    while (_sizeWaiters.isNotEmpty) {
      final chunk = _sizeWaiters.keys.take(128).toList();
      List<(int, int)> sizes;
      try {
        sizes = await AndroidFiles.sizes(chunk);
      } catch (_) {
        sizes = const [];
      }
      for (var j = 0; j < chunk.length; j++) {
        final c = _sizeWaiters.remove(chunk[j]);
        if (c == null || c.isCompleted) continue; // cancelled meanwhile
        final s = j < sizes.length ? sizes[j] : (0, 0);
        c.complete(
            s.$1 > 0 && s.$2 > 0 ? Size(s.$1.toDouble(), s.$2.toDouble()) : null);
      }
    }
    _sizeFlush = null;
  }

  /// Resolves source dimensions via the platform image codec's header
  /// (supports HEIC on Android/iOS) without decoding pixels.
  Future<Size?> _descriptorDimensions(File f) async {
    try {
      final bytes = await f.readAsBytes();
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      final w = descriptor.width, h = descriptor.height;
      descriptor.dispose();
      buffer.dispose();
      if (w > 0 && h > 0) return Size(w.toDouble(), h.toDouble());
    } catch (_) {}
    return null;
  }

  /// Android/iOS image thumbnail: decode (HEIC native) downscaled to [maxDim]
  /// and cache as PNG so the gallery isn't loading full-resolution originals.
  Future<bool> _decodeResize(String src, String dst, int maxDim) async {
    try {
      final bytes = await File(src).readAsBytes();
      final codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: maxDim > 0 ? maxDim : null,
        allowUpscaling: false,
      );
      final frame = await codec.getNextFrame();
      final data =
          await frame.image.toByteData(format: ui.ImageByteFormat.png);
      frame.image.dispose();
      codec.dispose();
      if (data == null) return false;
      await File(dst).writeAsBytes(data.buffer.asUint8List(), flush: true);
      return true;
    } catch (_) {
      return false;
    }
  }

  final _videoThumbPlugin = FcNativeVideoThumbnail();

  /// Video poster via the native plugin (Android/iOS/macOS).
  Future<bool> _videoThumb(String src, String dst, int maxDim) async {
    try {
      final ok = await _videoThumbPlugin.saveThumbnailToFile(
        srcFile: src,
        destFile: dst,
        width: maxDim,
        height: maxDim,
        format: 'jpeg',
        quality: 80,
      );
      return ok && await File(dst).exists();
    } catch (_) {
      return false;
    }
  }

  // ---- macOS process helpers ----

  Future<bool> _sipsResize(String src, String dst, int maxDim) async {
    try {
      final args = <String>['-s', 'format', 'jpeg'];
      if (maxDim > 0) args.addAll(['-Z', '$maxDim']);
      args.addAll([src, '--out', dst]);
      final r = await Process.run('sips', args);
      return r.exitCode == 0 && await File(dst).exists();
    } catch (_) {
      return false;
    }
  }

  Future<bool> _qlThumb(String src, String dst, int maxDim) async {
    try {
      final tmpDir = await Directory.systemTemp.createTemp('ql_');
      final r = await Process.run('qlmanage',
          ['-t', '-s', '${maxDim <= 0 ? 1024 : maxDim}', '-o', tmpDir.path, src]);
      if (r.exitCode != 0) {
        await tmpDir.delete(recursive: true);
        return false;
      }
      // qlmanage writes "<basename>.png" into the output dir.
      final produced = await tmpDir
          .list()
          .where((e) => e is File && e.path.endsWith('.png'))
          .cast<File>()
          .toList();
      if (produced.isEmpty) {
        await tmpDir.delete(recursive: true);
        return false;
      }
      await produced.first.copy(dst);
      await tmpDir.delete(recursive: true);
      return await File(dst).exists();
    } catch (_) {
      return false;
    }
  }

  /// Reads image dimensions from the file header (PNG/JPEG) without decoding
  /// the pixels — cheap and avoids spinning up the image codec.
  Future<Size?> _readImageDimensions(File f) async {
    try {
      final bytes = await f.readAsBytes();
      return _parseHeaderDimensions(bytes);
    } catch (_) {
      return null;
    }
  }

  /// Parses width/height from PNG and JPEG headers without a full decode.
  Size? _parseHeaderDimensions(Uint8List b) {
    // PNG: 8-byte sig, then IHDR (width @16, height @20, big-endian).
    if (b.length > 24 &&
        b[0] == 0x89 &&
        b[1] == 0x50 &&
        b[2] == 0x4E &&
        b[3] == 0x47) {
      final w = (b[16] << 24) | (b[17] << 16) | (b[18] << 8) | b[19];
      final h = (b[20] << 24) | (b[21] << 16) | (b[22] << 8) | b[23];
      if (w > 0 && h > 0) return Size(w.toDouble(), h.toDouble());
    }
    // JPEG: scan for SOF0..SOF15 markers (excluding DHT/DAC/etc.).
    if (b.length > 4 && b[0] == 0xFF && b[1] == 0xD8) {
      var i = 2;
      while (i + 9 < b.length) {
        if (b[i] != 0xFF) {
          i++;
          continue;
        }
        final marker = b[i + 1];
        final isSOF = (marker >= 0xC0 && marker <= 0xCF) &&
            marker != 0xC4 &&
            marker != 0xC8 &&
            marker != 0xCC;
        final segLen = (b[i + 2] << 8) | b[i + 3];
        if (isSOF) {
          final h = (b[i + 5] << 8) | b[i + 6];
          final w = (b[i + 7] << 8) | b[i + 8];
          if (w > 0 && h > 0) return Size(w.toDouble(), h.toDouble());
        }
        if (segLen <= 0) break;
        i += 2 + segLen;
      }
    }
    return null;
  }
}

/// A tiny concurrency limiter so we never spawn hundreds of decodes / `sips`
/// processes at once.
///
/// Waiters are served by priority rather than arrival: when a gallery is
/// flung, the tiles nearest the selection load first instead of working
/// through everything scrolled past. Combined with the per-request "still
/// wanted?" check and [ThumbCancel], stale off-screen requests cost almost
/// nothing.
class _Pool {
  _Pool(this.maxConcurrent, {bool Function()? paused})
      : _paused = paused ?? _never;
  final int maxConcurrent;
  final bool Function() _paused;
  static bool _never() => false;
  int _active = 0;
  int _seq = 0;
  final List<_Waiter> _waiting = [];

  /// Runs [task] when a slot is free. When several are waiting, the one with
  /// the lowest [priority] (e.g. a grid tile's distance from the middle of the
  /// screen, evaluated at that moment) goes next; requests without one (the
  /// viewer, slideshow) go first; ties fall back to most-recent-first.
  ///
  /// [urgent] work (an explicit user request) isn't held back by a pause.
  Future<T> run<T>(Future<T> Function() task,
      {double Function()? priority, bool urgent = false}) async {
    if (_active >= maxConcurrent || (!urgent && _paused())) {
      final w = _Waiter(priority, _seq++);
      _waiting.add(w);
      await w.completer.future;
      if (_starting > 0) _starting--;
    }
    _active++;
    try {
      return await task();
    } finally {
      _active--;
      _startNext();
    }
  }

  /// Starts waiters again after a pause (see [ThumbnailService.setVideoPlaying]).
  void resume() {
    while (!_paused() &&
        _active + _starting < maxConcurrent &&
        _waiting.isNotEmpty) {
      _starting++;
      _startNext();
    }
  }

  // Waiters released but not yet counted in [_active] (they resume on a later
  // microtask), so [resume] doesn't over-release.
  int _starting = 0;

  void _startNext() {
    if (_waiting.isEmpty || _paused()) return;
    var best = _waiting.first;
    var bestScore = best.score();
    for (final w in _waiting.skip(1)) {
      final s = w.score();
      if (s < bestScore || (s == bestScore && w.seq > best.seq)) {
        best = w;
        bestScore = s;
      }
    }
    _waiting.remove(best);
    best.completer.complete();
  }
}

class _Waiter {
  _Waiter(this.priority, this.seq);
  final double Function()? priority;
  final int seq;
  final completer = Completer<void>();

  double score() => priority?.call() ?? -1;
}

/// Lets a caller abandon a thumbnail request, including one already being
/// decoded natively (e.g. a grid tile that scrolled away).
class ThumbCancel {
  bool _cancelled = false;
  void Function()? _onCancel;

  bool get cancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _onCancel?.call();
    _onCancel = null;
  }
}

class Size {
  const Size(this.width, this.height);
  final double width;
  final double height;
  double get aspect => height == 0 ? 1 : width / height;
}
