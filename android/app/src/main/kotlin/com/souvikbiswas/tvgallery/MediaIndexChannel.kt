package com.souvikbiswas.tvgallery

import android.content.Context
import android.database.Cursor
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.ExifInterface
import android.media.ThumbnailUtils
import android.os.Build
import android.os.CancellationSignal
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.storage.StorageManager
import android.provider.MediaStore
import android.provider.MediaStore.Files.FileColumns
import android.util.Size
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.Executors

/**
 * Lightweight MediaStore queries for the folder browser.
 *
 * photo_manager's asset listing materialises a full entity per file — including
 * a `File.exists()` per asset and, when MediaStore lacks dimensions, opening the
 * file to read EXIF / video metadata. On a USB drive with tens of thousands of
 * files that takes minutes. Here we only project the handful of columns we need
 * and aggregate in a single cursor pass, so the folder tree is ready in well
 * under a second; a folder's items are fetched only when it's opened.
 *
 * With "All files access" the browser instead reads drives directly
 * ([volumes], [listDir]) — complete and instant even while Android is still
 * indexing a USB drive — using MediaStore only to enrich files it has already
 * indexed, and generating thumbnails / sizes natively for the rest.
 */
class MediaIndexChannel(private val context: Context, messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, "tv_gallery/media_index")
    private val worker = Executors.newSingleThreadExecutor()

    // Thumbnail decodes get their own threads so a burst of them never queues
    // ahead of a folder listing. The Dart side already caps concurrency.
    private val decoders = Executors.newFixedThreadPool(3)

    // In-flight / queued thumbnail requests by Dart-side id, so a tile that
    // scrolled away can cancel its decode.
    private val thumbSignals = ConcurrentHashMap<Int, CancellationSignal>()
    private val summaryCancels = ConcurrentHashMap<Int, AtomicBoolean>()

    // Recursive folder-card summaries, kept off the listing thread too.
    private val walkers = Executors.newFixedThreadPool(2)

    // Header-size reads: one coordinator per request fanning out to a small
    // pool — USB reads overlap well, and a big folder needs thousands.
    private val sizeCoordinator = Executors.newSingleThreadExecutor()
    private val sizers = Executors.newFixedThreadPool(4)
    private val main = Handler(Looper.getMainLooper())

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "folders" -> runAsync(result) { folders() }
            "list" -> {
                val keys = call.argument<List<String>>("keys") ?: emptyList()
                runAsync(result) { list(keys) }
            }
            "volumes" -> runAsync(result) { volumes() }
            "listDir" -> {
                val path = call.argument<String>("path") ?: ""
                runAsync(result) { listDir(path) }
            }
            "renamePath" -> {
                val path = call.argument<String>("path") ?: ""
                val name = call.argument<String>("name") ?: ""
                runAsync(result) { renamePath(path, name) }
            }
            "deletePath" -> {
                val path = call.argument<String>("path") ?: ""
                runAsync(result) { File(path).deleteRecursively() }
            }
            "dirs" -> {
                val path = call.argument<String>("path") ?: ""
                runAsync(result) { dirs(path) }
            }
            "summary" -> {
                val path = call.argument<String>("path") ?: ""
                val id = call.argument<Int>("id") ?: -1
                val cancelled = AtomicBoolean(false)
                if (id >= 0) summaryCancels[id] = cancelled
                runAsync(result, walkers) {
                    try {
                        summary(path, cancelled)
                    } finally {
                        if (id >= 0) summaryCancels.remove(id)
                    }
                }
            }
            "cancelSummary" -> {
                call.argument<Int>("id")?.let { summaryCancels.remove(it)?.set(true) }
                result.success(null)
            }
            "sizes" -> {
                val paths = call.argument<List<String>>("paths") ?: emptyList()
                runAsync(result, sizeCoordinator) { sizes(paths) }
            }
            "thumb" -> {
                val path = call.argument<String>("path") ?: ""
                val dst = call.argument<String>("dst") ?: ""
                val maxDim = call.argument<Int>("maxDim") ?: 480
                val quality = call.argument<Int>("quality") ?: 80
                val isVideo = call.argument<Boolean>("isVideo") ?: false
                val id = call.argument<Int>("id") ?: -1
                val signal = CancellationSignal()
                if (id >= 0) thumbSignals[id] = signal
                runAsync(result, decoders) {
                    try {
                        thumb(path, dst, maxDim, quality, isVideo, signal)
                    } finally {
                        if (id >= 0) thumbSignals.remove(id)
                    }
                }
            }
            "cancelThumb" -> {
                call.argument<Int>("id")?.let { thumbSignals.remove(it)?.cancel() }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun runAsync(
        result: MethodChannel.Result,
        executor: java.util.concurrent.Executor = worker,
        block: () -> Any?,
    ) {
        executor.execute {
            try {
                val value = block()
                main.post { result.success(value) }
            } catch (e: Exception) {
                main.post { result.error("media_index", e.message, null) }
            }
        }
    }

    private val usesRelativePath = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q
    private val uri = MediaStore.Files.getContentUri("external")
    private val mediaSelection =
        "${FileColumns.MEDIA_TYPE} IN (${FileColumns.MEDIA_TYPE_IMAGE}, ${FileColumns.MEDIA_TYPE_VIDEO})"

    /** Folder key for a row: RELATIVE_PATH on Q+, else the parent directory. */
    private fun keyColumn() =
        if (usesRelativePath) MediaStore.MediaColumns.RELATIVE_PATH else MediaStore.MediaColumns.DATA

    private fun Cursor.folderKey(col: Int): String {
        val raw = getString(col) ?: return ""
        return if (usesRelativePath) raw else File(raw).parent ?: ""
    }

    /** Date taken (ms), falling back to date added — matches photo_manager. */
    private fun Cursor.dateMs(taken: Int, added: Int): Long {
        val t = if (taken >= 0) getLong(taken) else 0L
        return if (t > 0) t else getLong(added) * 1000
    }

    private class Agg {
        var count = 0
        var imageId = -1L
        var imageDate = Long.MIN_VALUE
        var imageW = 0
        var imageH = 0
        var videoId = -1L
        var videoDate = Long.MIN_VALUE
        var videoW = 0
        var videoH = 0
    }

    /**
     * One row per folder that directly contains media:
     * `[key, count, coverId, coverIsVideo, coverW, coverH]`. The cover is the
     * newest still image, else the newest video.
     */
    private fun folders(): List<List<Any?>> {
        val projection = arrayOf(
            FileColumns._ID,
            keyColumn(),
            FileColumns.MEDIA_TYPE,
            MediaStore.MediaColumns.DATE_ADDED,
            MediaStore.MediaColumns.WIDTH,
            MediaStore.MediaColumns.HEIGHT,
        ) + (if (usesRelativePath) arrayOf(
            MediaStore.MediaColumns.DATE_TAKEN,
            MediaStore.MediaColumns.ORIENTATION,
        ) else emptyArray())

        val byKey = HashMap<String, Agg>()
        context.contentResolver.query(uri, projection, mediaSelection, null, null)?.use { c ->
            val idCol = c.getColumnIndexOrThrow(FileColumns._ID)
            val keyCol = c.getColumnIndexOrThrow(keyColumn())
            val typeCol = c.getColumnIndexOrThrow(FileColumns.MEDIA_TYPE)
            val addedCol = c.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_ADDED)
            val takenCol = c.getColumnIndex(MediaStore.MediaColumns.DATE_TAKEN)
            val wCol = c.getColumnIndexOrThrow(MediaStore.MediaColumns.WIDTH)
            val hCol = c.getColumnIndexOrThrow(MediaStore.MediaColumns.HEIGHT)
            val oCol = c.getColumnIndex(MediaStore.MediaColumns.ORIENTATION)
            while (c.moveToNext()) {
                val agg = byKey.getOrPut(c.folderKey(keyCol)) { Agg() }
                agg.count++
                val date = c.dateMs(takenCol, addedCol)
                val isVideo = c.getInt(typeCol) == FileColumns.MEDIA_TYPE_VIDEO
                if (!isVideo && date > agg.imageDate) {
                    agg.imageDate = date
                    agg.imageId = c.getLong(idCol)
                    val (w, h) = c.orientedSize(wCol, hCol, oCol)
                    agg.imageW = w; agg.imageH = h
                } else if (isVideo && date > agg.videoDate) {
                    agg.videoDate = date
                    agg.videoId = c.getLong(idCol)
                    agg.videoW = c.getInt(wCol); agg.videoH = c.getInt(hCol)
                }
            }
        }
        // Sorted so an unchanged library yields identical rows (Dart skips the rebuild).
        return byKey.toSortedMap().map { (key, a) ->
            val useImage = a.imageId >= 0
            listOf(
                key,
                a.count,
                (if (useImage) a.imageId else a.videoId).toString(),
                !useImage,
                if (useImage) a.imageW else a.videoW,
                if (useImage) a.imageH else a.videoH,
            )
        }
    }

    /**
     * Media directly inside the folder(s) with the given keys (several raw keys
     * can map to one browser folder, e.g. the same path on two volumes):
     * `[id, name, isVideo, dateMs, width, height]`.
     */
    private fun list(keys: List<String>): List<List<Any?>> {
        if (keys.isEmpty()) return emptyList()
        val projection = arrayOf(
            FileColumns._ID,
            keyColumn(),
            FileColumns.MEDIA_TYPE,
            MediaStore.MediaColumns.DISPLAY_NAME,
            MediaStore.MediaColumns.DATE_ADDED,
            MediaStore.MediaColumns.WIDTH,
            MediaStore.MediaColumns.HEIGHT,
        ) + (if (usesRelativePath) arrayOf(
            MediaStore.MediaColumns.DATE_TAKEN,
            MediaStore.MediaColumns.ORIENTATION,
        ) else emptyArray())

        val selection: String
        val args: Array<String>
        if (usesRelativePath) {
            selection = "$mediaSelection AND ${MediaStore.MediaColumns.RELATIVE_PATH} IN (" +
                keys.joinToString(",") { "?" } + ")"
            args = keys.toTypedArray()
        } else {
            // Pre-Q: prefix match on the absolute path, then keep direct children.
            selection = "$mediaSelection AND (" +
                keys.joinToString(" OR ") { "${MediaStore.MediaColumns.DATA} LIKE ?" } + ")"
            args = keys.map { "$it/%" }.toTypedArray()
        }
        val wanted = keys.toHashSet()
        val out = ArrayList<List<Any?>>()
        context.contentResolver.query(uri, projection, selection, args, null)?.use { c ->
            val idCol = c.getColumnIndexOrThrow(FileColumns._ID)
            val keyCol = c.getColumnIndexOrThrow(keyColumn())
            val typeCol = c.getColumnIndexOrThrow(FileColumns.MEDIA_TYPE)
            val nameCol = c.getColumnIndexOrThrow(MediaStore.MediaColumns.DISPLAY_NAME)
            val addedCol = c.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_ADDED)
            val takenCol = c.getColumnIndex(MediaStore.MediaColumns.DATE_TAKEN)
            val wCol = c.getColumnIndexOrThrow(MediaStore.MediaColumns.WIDTH)
            val hCol = c.getColumnIndexOrThrow(MediaStore.MediaColumns.HEIGHT)
            val oCol = c.getColumnIndex(MediaStore.MediaColumns.ORIENTATION)
            while (c.moveToNext()) {
                if (!usesRelativePath && c.folderKey(keyCol) !in wanted) continue
                val id = c.getLong(idCol)
                val (w, h) = c.orientedSize(wCol, hCol, oCol)
                out.add(listOf(
                    id.toString(),
                    c.getString(nameCol) ?: id.toString(),
                    c.getInt(typeCol) == FileColumns.MEDIA_TYPE_VIDEO,
                    c.dateMs(takenCol, addedCol),
                    w,
                    h,
                ))
            }
        }
        return out
    }

    /** Pixel size as displayed — swaps width/height for 90°/270° rotations. */
    private fun Cursor.orientedSize(wCol: Int, hCol: Int, oCol: Int): Pair<Int, Int> {
        val w = getInt(wCol)
        val h = getInt(hCol)
        val o = if (oCol >= 0) getInt(oCol) else 0
        return if (o == 90 || o == 270) h to w else w to h
    }

    // ---- Direct filesystem access (requires "All files access") ----

    private val imageExts = setOf(
        "heic", "heif", "jpg", "jpeg", "png", "gif", "webp", "bmp", "tif", "tiff",
    )
    private val videoExts = setOf(
        "mov", "mp4", "m4v", "avi", "mkv", "3gp", "webm", "mpg", "mpeg",
    )
    private val ignoredNames = setOf("System Volume Information", "\$RECYCLE.BIN", "LOST.DIR")

    /** Mounted storage volumes: `[path, description, isRemovable]`, USB first. */
    private fun volumes(): List<List<Any?>> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return emptyList()
        val sm = context.getSystemService(StorageManager::class.java)
        return sm.storageVolumes
            .filter { it.state == Environment.MEDIA_MOUNTED && it.directory != null }
            .sortedBy { if (it.isRemovable) 0 else 1 }
            .map { listOf(it.directory!!.absolutePath, it.getDescription(context), it.isRemovable) }
    }

    /**
     * Renames a file/folder in place; returns the new path, or throws with a
     * readable reason. (MediaStore picks the change up itself: drive access
     * goes through its FUSE layer.)
     */
    private fun renamePath(path: String, name: String): String {
        val src = File(path)
        val dst = File(src.parentFile, name)
        if (!src.exists()) throw IllegalStateException("It no longer exists")
        if (dst.exists()) throw IllegalStateException("“$name” already exists")
        if (!src.renameTo(dst)) throw IllegalStateException("The drive refused the new name")
        return dst.absolutePath
    }

    /** EXIF DateTimeOriginal of a photo (ms), else the file's modified time. */
    private fun captureDate(path: String, isVideo: Boolean): Long? {
        if (!isVideo) {
            try {
                val exif = ExifInterface(path)
                val raw = exif.getAttribute(ExifInterface.TAG_DATETIME_ORIGINAL)
                    ?: exif.getAttribute(ExifInterface.TAG_DATETIME)
                if (raw != null) {
                    val fmt = java.text.SimpleDateFormat("yyyy:MM:dd HH:mm:ss", java.util.Locale.US)
                    fmt.parse(raw)?.let { return it.time }
                }
            } catch (e: Exception) {
                // No/unreadable EXIF — fall back to the file date.
            }
        }
        val modified = File(path).lastModified()
        return if (modified > 0) modified else null
    }

    private fun isMedia(name: String): Boolean {
        val ext = name.substringAfterLast('.', "").lowercase()
        return ext in imageExts || ext in videoExts
    }

    private fun isIgnored(name: String) = name.startsWith(".") || name in ignoredNames

    /**
     * Subfolder names of a real directory. Names come from a plain listing (no
     * per-entry stat — over the USB FUSE mount that's what makes listing a
     * big folder slow); only non-media names are checked for being folders.
     */
    private fun dirs(path: String): List<String> {
        val dir = File(path)
        return (dir.list() ?: return emptyList())
            .filter { !isIgnored(it) && !isMedia(it) && File(dir, it).isDirectory }
    }

    /**
     * Recursive folder-card summary: `[mediaCount, subfolderCount, coverPath,
     * coverIsVideo, dateMs?]`. The cover is the first still image (by name),
     * else the first video; its capture date (EXIF, else the file's date) is
     * the folder's date for date sorting.
     */
    private fun summary(path: String, cancelled: AtomicBoolean): List<Any?>? {
        var count = 0
        var subfolders = 0
        var image: String? = null
        var video: String? = null
        fun walk(dir: File, top: Boolean) {
            if (cancelled.get()) return
            val names = dir.list() ?: return
            names.sort()
            for (n in names) {
                if (isIgnored(n)) continue
                if (isMedia(n)) {
                    count++
                    val isVideo = n.substringAfterLast('.', "").lowercase() in videoExts
                    if (isVideo) {
                        if (video == null) video = File(dir, n).path
                    } else if (image == null) {
                        image = File(dir, n).path
                    }
                } else {
                    val child = File(dir, n)
                    if (child.isDirectory) {
                        if (top) subfolders++
                        walk(child, false)
                    }
                }
            }
        }
        walk(File(path), true)
        if (cancelled.get()) return null
        val cover = image ?: video
        return listOf(
            count, subfolders, cover, image == null && video != null,
            cover?.let { captureDate(it, isVideo = image == null) },
        )
    }

    private class Indexed(
        val id: Long, val isVideo: Boolean, val date: Long, val size: Long,
        val w: Int, val h: Int,
    )

    /**
     * Lists a real directory: `{dirs: [name], files: [[name, isVideo, dateMs,
     * size, w, h, assetId?]]}`. Only names without a media extension are
     * stat'd (to tell folders apart); media files already in MediaStore take
     * their date/size/dimensions/id from it, the rest are stat'd once.
     */
    private fun listDir(path: String): Map<String, Any?> {
        val dir = File(path)
        val names = dir.list() ?: return mapOf("dirs" to emptyList<String>(), "files" to emptyList<Any>())
        val dirs = ArrayList<String>()
        val media = ArrayList<String>()
        for (n in names) {
            if (isIgnored(n)) continue
            if (isMedia(n)) {
                media.add(n)
            } else if (File(dir, n).isDirectory) {
                dirs.add(n)
            }
        }
        val indexed = if (media.isEmpty()) emptyMap() else indexedIn(dir.absolutePath)
        val files = media.map { n ->
            val isVideo = n.substringAfterLast('.', "").lowercase() in videoExts
            val r = indexed[n]
            if (r != null) {
                listOf(n, r.isVideo, r.date, r.size, r.w, r.h, r.id.toString())
            } else {
                val f = File(dir, n)
                listOf(n, isVideo, f.lastModified(), f.length(), 0, 0, null)
            }
        }
        return mapOf("dirs" to dirs, "files" to files)
    }

    /** MediaStore rows for media directly inside [dirPath], keyed by file name. */
    private fun indexedIn(dirPath: String): Map<String, Indexed> {
        val projection = arrayOf(
            FileColumns._ID,
            MediaStore.MediaColumns.DATA,
            FileColumns.MEDIA_TYPE,
            MediaStore.MediaColumns.SIZE,
            MediaStore.MediaColumns.DATE_MODIFIED,
            MediaStore.MediaColumns.WIDTH,
            MediaStore.MediaColumns.HEIGHT,
        ) + (if (usesRelativePath) arrayOf(
            MediaStore.MediaColumns.DATE_TAKEN,
            MediaStore.MediaColumns.ORIENTATION,
        ) else emptyArray())
        val escaped = dirPath.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
        val selection = "$mediaSelection AND ${MediaStore.MediaColumns.DATA} LIKE ? ESCAPE '\\'"
        val out = HashMap<String, Indexed>()
        try {
            context.contentResolver.query(uri, projection, selection, arrayOf("$escaped/%"), null)?.use { c ->
                val idCol = c.getColumnIndexOrThrow(FileColumns._ID)
                val dataCol = c.getColumnIndexOrThrow(MediaStore.MediaColumns.DATA)
                val typeCol = c.getColumnIndexOrThrow(FileColumns.MEDIA_TYPE)
                val sizeCol = c.getColumnIndexOrThrow(MediaStore.MediaColumns.SIZE)
                val modCol = c.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_MODIFIED)
                val takenCol = c.getColumnIndex(MediaStore.MediaColumns.DATE_TAKEN)
                val wCol = c.getColumnIndexOrThrow(MediaStore.MediaColumns.WIDTH)
                val hCol = c.getColumnIndexOrThrow(MediaStore.MediaColumns.HEIGHT)
                val oCol = c.getColumnIndex(MediaStore.MediaColumns.ORIENTATION)
                while (c.moveToNext()) {
                    val file = File(c.getString(dataCol) ?: continue)
                    if (file.parent != dirPath) continue // deeper subfolder
                    val (w, h) = c.orientedSize(wCol, hCol, oCol)
                    out[file.name] = Indexed(
                        id = c.getLong(idCol),
                        isVideo = c.getInt(typeCol) == FileColumns.MEDIA_TYPE_VIDEO,
                        date = c.dateMs(takenCol, modCol),
                        size = c.getLong(sizeCol),
                        w = w,
                        h = h,
                    )
                }
            }
        } catch (e: Exception) {
            // Not indexed / not queryable — every file falls back to a stat.
        }
        return out
    }

    /**
     * Displayed pixel size of each image, read from the header only (no pixel
     * decode) and corrected for rotation: `[w, h]`, `[0, 0]` if unknown.
     */
    private fun sizes(paths: List<String>): List<List<Int>> =
        paths.map { p -> sizers.submit<List<Int>> { sizeOf(p) } }.map { it.get() }

    private fun sizeOf(path: String): List<Int> {
        try {
            // Seek-and-read only the bytes that hold the size: over the USB
            // FUSE mount, bytes read (not files opened) is what costs.
            java.io.RandomAccessFile(path, "r").use { raf ->
                (HeaderSize.jpeg(raf) ?: HeaderSize.heif(raf) ?: HeaderSize.png(raf))
                    ?.let { return listOf(it.first, it.second) }
            }
        } catch (e: Exception) {
            // Fall through to the platform decoder.
        }
        return try {
            val o = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(path, o)
            var w = maxOf(o.outWidth, 0)
            var h = maxOf(o.outHeight, 0)
            if (w > 0 && h > 0) {
                val orientation = ExifInterface(path).getAttributeInt(
                    ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL,
                )
                if (orientation in 5..8) {
                    val t = w; w = h; h = t
                }
            }
            listOf(w, h)
        } catch (e: Exception) {
            listOf(0, 0)
        }
    }

    /**
     * Writes a JPEG thumbnail of an image or video to [dst] using the platform
     * thumbnailer (embedded EXIF thumbnails / sampled hardware decode, EXIF
     * rotation applied) — far cheaper than decoding the full original.
     */
    private fun thumb(
        path: String, dst: String, maxDim: Int, quality: Int, isVideo: Boolean,
        signal: CancellationSignal,
    ): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q || signal.isCanceled) return false
        return try {
            val size = Size(maxDim, maxDim)
            val bmp = if (isVideo) {
                ThumbnailUtils.createVideoThumbnail(File(path), size, signal)
            } else {
                ThumbnailUtils.createImageThumbnail(File(path), size, signal)
            }
            FileOutputStream(dst).use { bmp.compress(Bitmap.CompressFormat.JPEG, quality, it) }
            bmp.recycle()
            true
        } catch (e: Exception) {
            if (!signal.isCanceled) android.util.Log.w("TvGallery", "thumb failed: $path", e)
            File(dst).delete()
            false
        }
    }
}

/**
 * Minimal image-header parsers returning the *displayed* (rotation-corrected)
 * size, reading as few bytes as possible (seeking past everything else), or
 * null if the format isn't recognised.
 */
private object HeaderSize {
    private fun u16be(b: ByteArray, i: Int) = ((b[i].toInt() and 0xFF) shl 8) or (b[i + 1].toInt() and 0xFF)
    private fun u32be(b: ByteArray, i: Int): Long =
        ((b[i].toLong() and 0xFF) shl 24) or ((b[i + 1].toLong() and 0xFF) shl 16) or
            ((b[i + 2].toLong() and 0xFF) shl 8) or (b[i + 3].toLong() and 0xFF)

    private fun read(raf: java.io.RandomAccessFile, pos: Long, n: Int): ByteArray? {
        if (pos < 0 || n <= 0 || pos + n > raf.length()) return null
        val b = ByteArray(n)
        raf.seek(pos)
        raf.readFully(b)
        return b
    }

    fun png(raf: java.io.RandomAccessFile): Pair<Int, Int>? {
        val b = read(raf, 0, 24) ?: return null
        if (b[0] != 0x89.toByte() || b[1] != 'P'.code.toByte()) return null
        return u32be(b, 16).toInt() to u32be(b, 20).toInt()
    }

    /** JPEG: walk marker segments (4-byte headers) to SOFn; EXIF orientation. */
    fun jpeg(raf: java.io.RandomAccessFile): Pair<Int, Int>? {
        val soi = read(raf, 0, 2) ?: return null
        if (soi[0] != 0xFF.toByte() || soi[1] != 0xD8.toByte()) return null
        var pos = 2L
        var orientation = 1
        repeat(64) {
            val h = read(raf, pos, 4) ?: return null
            if (h[0] != 0xFF.toByte()) return null
            val marker = h[1].toInt() and 0xFF
            val len = u16be(h, 2)
            if (marker == 0xE1) {
                // Exif header (6) + TIFF IFD0 — the first few KB is plenty.
                val seg = read(raf, pos + 4, minOf(len - 2, 4096))
                if (seg != null && seg.size > 14 && String(seg, 0, 4, Charsets.US_ASCII) == "Exif") {
                    orientation = exifOrientation(seg, 6, seg.size)
                }
            }
            val isSof = marker in 0xC0..0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC
            if (isSof) {
                val f = read(raf, pos + 5, 4) ?: return null
                val hgt = u16be(f, 0)
                val w = u16be(f, 2)
                if (w <= 0 || hgt <= 0) return null
                return if (orientation in 5..8) hgt to w else w to hgt
            }
            if (len < 2) return null
            pos += 2 + len
        }
        return null
    }

    /** Orientation tag (0x0112) from IFD0 of the TIFF block at [t]. */
    private fun exifOrientation(b: ByteArray, t: Int, end: Int): Int {
        if (t + 8 > end) return 1
        val le = b[t] == 'I'.code.toByte()
        fun u16(i: Int) = if (le) (b[i].toInt() and 0xFF) or ((b[i + 1].toInt() and 0xFF) shl 8) else u16be(b, i)
        fun u32(i: Int): Int = if (le) (u16(i) or (u16(i + 2) shl 16)) else u32be(b, i).toInt()
        val ifd = t + u32(t + 4)
        if (ifd < t || ifd + 2 > end) return 1
        val count = u16(ifd)
        for (k in 0 until count) {
            val e = ifd + 2 + k * 12
            if (e + 12 > end) break
            if (u16(e) == 0x0112) return u16(e + 8)
        }
        return 1
    }

    /**
     * HEIF/HEIC: finds the top-level `meta` box by its headers, reads just
     * that box, then takes the primary item's `ispe` (size) and `irot`
     * (rotation) via `pitm` and `iprp/ipco` + `ipma`.
     */
    fun heif(raf: java.io.RandomAccessFile): Pair<Int, Int>? {
        val ftyp = read(raf, 0, 8) ?: return null
        if (String(ftyp, 4, 4, Charsets.US_ASCII) != "ftyp") return null
        var pos = 0L
        repeat(16) {
            val h = read(raf, pos, 16) ?: read(raf, pos, 8) ?: return null
            var size = u32be(h, 0)
            var header = 8
            if (size == 1L && h.size >= 16) {
                size = (u32be(h, 8) shl 32) or u32be(h, 12)
                header = 16
            }
            if (size < header) return null
            if (String(h, 4, 4, Charsets.US_ASCII) == "meta") {
                if (size > 4 * 1024 * 1024) return null
                val meta = read(raf, pos + header, (size - header).toInt()) ?: return null
                return heifMeta(meta)
            }
            pos += size
        }
        return null
    }

    private fun heifMeta(b: ByteArray): Pair<Int, Int>? {
        val body = 4 // FullBox version/flags
        val pitm = findBox(b, body, b.size, "pitm") ?: return null
        val primary = if (b[pitm.first].toInt() == 0) u16be(b, pitm.first + 4).toLong() else u32be(b, pitm.first + 4)
        val iprp = findBox(b, body, b.size, "iprp") ?: return null
        val ipco = findBox(b, iprp.first, iprp.second, "ipco") ?: return null
        val ipma = findBox(b, iprp.first, iprp.second, "ipma") ?: return null

        // Property boxes in ipco, 1-based: (type, bodyStart).
        val props = ArrayList<Pair<String, Int>>()
        var p = ipco.first
        while (p + 8 <= ipco.second) {
            val size = u32be(b, p).toInt()
            if (size < 8 || p + size > ipco.second) break
            props.add(String(b, p + 4, 4, Charsets.US_ASCII) to p + 8)
            p += size
        }

        val version = b[ipma.first].toInt()
        val flags = b[ipma.first + 3].toInt() and 1
        var q = ipma.first + 4
        val entries = u32be(b, q).toInt(); q += 4
        var w = 0
        var h = 0
        var angle = 0
        for (e in 0 until entries) {
            if (q + 3 > ipma.second) return null
            val itemId = if (version < 1) u16be(b, q).toLong().also { q += 2 } else u32be(b, q).also { q += 4 }
            val n = b[q].toInt() and 0xFF; q++
            for (a in 0 until n) {
                val idx = if (flags == 1) (u16be(b, q) and 0x7FFF).also { q += 2 } else (b[q].toInt() and 0x7F).also { q++ }
                if (itemId != primary || idx < 1 || idx > props.size) continue
                val (type, start) = props[idx - 1]
                when (type) {
                    "ispe" -> { w = u32be(b, start + 4).toInt(); h = u32be(b, start + 8).toInt() }
                    "irot" -> angle = b[start].toInt() and 3
                }
            }
        }
        if (w <= 0 || h <= 0) return null
        return if (angle == 1 || angle == 3) h to w else w to h
    }

    /** First child box of [type] within [start, end): (bodyStart, boxEnd). */
    private fun findBox(b: ByteArray, start: Int, end: Int, type: String): Pair<Int, Int>? {
        var i = start
        while (i + 8 <= end) {
            val size = u32be(b, i).toInt()
            if (size < 8) return null
            val boxEnd = minOf(i + size, end)
            if (String(b, i + 4, 4, Charsets.US_ASCII) == type) return (i + 8) to boxEnd
            i += size
        }
        return null
    }
}
