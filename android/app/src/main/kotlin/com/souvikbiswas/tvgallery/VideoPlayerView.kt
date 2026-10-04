package com.souvikbiswas.tvgallery

import android.content.Context
import android.graphics.Typeface
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.TypedValue
import android.view.Gravity
import android.view.SurfaceView
import android.view.View
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.trackselection.DefaultTrackSelector
import androidx.media3.exoplayer.analytics.AnalyticsListener
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.platform.PlatformView
import java.io.File

/**
 * A Flutter PlatformView that plays a local video with ExoPlayer (Media3),
 * rendering to a [SurfaceView]. Because the frames go straight to the display
 * compositor (not a Flutter texture), the TV gets true HDR10/HLG/Dolby Vision
 * passthrough and smooth high-frame-rate playback.
 *
 * Control flows over a per-view MethodChannel; playback state is streamed back
 * over a per-view EventChannel. Flutter owns play/pause decisions — we only
 * prepare the media here.
 */
class VideoPlayerView(
    context: Context,
    id: Int,
    params: Map<*, *>?,
    messenger: BinaryMessenger,
) : PlatformView, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private val surfaceView = SurfaceView(context)
    // Centers the surface and sizes it to the video's aspect ratio so vertical
    // (or anamorphic) videos are letter/pillar-boxed instead of stretched.
    private val frame = AspectFitLayout(context).apply {
        addView(
            surfaceView,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT,
            ),
        )
    }

    // Date/place caption drawn natively, inside this view. A Flutter caption
    // on top of the video would need its own full-screen layer composited over
    // the video every frame (on this TV that dropped most frames of 4K/60fps
    // clips); these views render into the window layer that exists anyway.
    private val density = context.resources.displayMetrics.density
    private val captionPlace = captionText(context, "Inter-Medium.ttf")
    private val captionDate = captionText(context, "Inter-SemiBold.ttf")
    private val caption = LinearLayout(context).apply {
        orientation = LinearLayout.VERTICAL
        alpha = 0.6f
        visibility = View.GONE
        addView(captionPlace)
        addView(captionDate)
        (captionDate.layoutParams as LinearLayout.LayoutParams).topMargin = (3 * density).toInt()
    }
    private val root = FrameLayout(context).apply {
        addView(frame, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT,
        ))
        addView(caption, FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT,
            Gravity.BOTTOM or Gravity.START,
        ).apply {
            // Same spot as the Flutter caption on photos (left 20, bottom 18).
            leftMargin = (20 * density).toInt()
            bottomMargin = (18 * density).toInt()
        })
    }

    private fun captionText(context: Context, font: String) = TextView(context).apply {
        setTextColor(0xFFFFFFFF.toInt())
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
        setShadowLayer(8 * density, 0f, 0f, 0x8A000000.toInt())
        includeFontPadding = false
        typeface = try {
            // The app's own Inter, bundled in the Flutter assets.
            Typeface.createFromAsset(context.assets, "flutter_assets/assets/fonts/$font")
        } catch (e: Exception) {
            Typeface.DEFAULT_BOLD
        }
    }

    private fun setCaption(date: String?, place: String?) {
        captionPlace.text = place ?: ""
        captionPlace.visibility = if (place.isNullOrEmpty()) View.GONE else View.VISIBLE
        captionDate.text = date ?: ""
        captionDate.visibility = if (date.isNullOrEmpty()) View.GONE else View.VISIBLE
        caption.visibility =
            if (date.isNullOrEmpty() && place.isNullOrEmpty()) View.GONE else View.VISIBLE
    }

    // Tunneled playback: decoded frames go straight from the decoder to the
    // TV's video pipeline (timed by the hardware) instead of through the app's
    // surface and the compositor. Without it, 4K/60fps Dolby Vision dropped
    // ~85% of frames on this TV. Used only when the decoders support it (and
    // there's an audio track); otherwise playback is unchanged.
    private val trackSelector = DefaultTrackSelector(context).apply {
        parameters = buildUponParameters().setTunnelingEnabled(true).build()
    }
    private val player: ExoPlayer =
        ExoPlayer.Builder(context).setTrackSelector(trackSelector).build()
    private val methodChannel = MethodChannel(messenger, "tv_gallery/video/$id")
    private val eventChannel = EventChannel(messenger, "tv_gallery/video_events/$id")
    private var events: EventChannel.EventSink? = null
    private val handler = Handler(Looper.getMainLooper())

    private val ticker = object : Runnable {
        override fun run() {
            send("position", player.currentPosition)
            handler.postDelayed(this, 250)
        }
    }

    init {
        player.setVideoSurfaceView(surfaceView)
        // Diagnostics for choppy playback: rebuffering (data not arriving fast
        // enough) vs dropped frames (decoder/render can't keep up).
        player.addAnalyticsListener(object : AnalyticsListener {
            override fun onPlaybackStateChanged(
                eventTime: AnalyticsListener.EventTime, state: Int,
            ) {
                if (state == Player.STATE_BUFFERING) {
                    android.util.Log.i("TvGalleryVideo", "buffering at ${player.currentPosition}ms")
                }
            }

            override fun onVideoInputFormatChanged(
                eventTime: AnalyticsListener.EventTime,
                format: androidx.media3.common.Format,
                decoderReuseEvaluation: androidx.media3.exoplayer.DecoderReuseEvaluation?,
            ) {
                android.util.Log.i(
                    "TvGalleryVideo",
                    "format ${format.sampleMimeType} ${format.codecs} " +
                        "${format.width}x${format.height} @${format.frameRate}fps " +
                        "bitrate=${format.bitrate} color=${format.colorInfo}",
                )
            }

            override fun onVideoDecoderInitialized(
                eventTime: AnalyticsListener.EventTime,
                decoderName: String,
                initializedTimestampMs: Long,
                initializationDurationMs: Long,
            ) {
                android.util.Log.i("TvGalleryVideo", "decoder $decoderName")
            }

            override fun onDroppedVideoFrames(
                eventTime: AnalyticsListener.EventTime, droppedFrames: Int, elapsedMs: Long,
            ) {
                android.util.Log.i("TvGalleryVideo", "dropped $droppedFrames frames in ${elapsedMs}ms")
            }
        })
        methodChannel.setMethodCallHandler(this)
        eventChannel.setStreamHandler(this)
        player.addListener(object : Player.Listener {
            override fun onPlaybackStateChanged(state: Int) {
                when (state) {
                    Player.STATE_READY -> send("ready", player.duration)
                    Player.STATE_ENDED -> send("completed", null)
                }
            }

            override fun onIsPlayingChanged(isPlaying: Boolean) {
                send("playing", isPlaying)
                if (isPlaying) {
                    handler.post(ticker)
                } else {
                    handler.removeCallbacks(ticker)
                }
            }

            override fun onPlayerError(error: PlaybackException) {
                send("error", error.message ?: "playback error")
            }

            override fun onVideoSizeChanged(videoSize: VideoSize) {
                var w = videoSize.width.toFloat() * videoSize.pixelWidthHeightRatio
                var h = videoSize.height.toFloat()
                // Rotation that the decoder hasn't applied flips the displayed
                // dimensions (e.g. portrait phone clips stored landscape).
                if (videoSize.unappliedRotationDegrees == 90 ||
                    videoSize.unappliedRotationDegrees == 270
                ) {
                    val tmp = w; w = h; h = tmp
                }
                frame.videoAspect = if (h > 0f) w / h else 0f
            }
        })

        val path = params?.get("path") as? String
        val muted = params?.get("muted") as? Boolean ?: false
        player.volume = if (muted) 0f else 1f
        if (path != null) open(path, autoplay = false)
    }

    private fun open(path: String, autoplay: Boolean) {
        val uri = if (path.contains("://")) Uri.parse(path) else Uri.fromFile(File(path))
        player.setMediaItem(MediaItem.fromUri(uri))
        player.prepare()
        player.playWhenReady = autoplay
    }

    private fun send(event: String, value: Any?) {
        events?.success(mapOf("event" to event, "value" to value))
    }

    override fun getView(): View = root

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "play" -> {
                // Re-prepare after "stop" (decoder released while inactive).
                if (player.playbackState == Player.STATE_IDLE) player.prepare()
                player.play()
                result.success(null)
            }
            "stop" -> {
                // Frees the hardware decoder now, rather than when the view is
                // torn down: the TV has few Dolby Vision/HEVC decoder resources,
                // and a lingering one starved the next video (decoder error
                // 0xc, then most frames dropped).
                player.stop()
                result.success(null)
            }
            "pause" -> {
                player.pause()
                result.success(null)
            }
            "seekTo" -> {
                val ms = (call.argument<Number>("ms") ?: 0).toLong()
                player.seekTo(ms)
                result.success(null)
            }
            "setVolume" -> {
                val v = (call.argument<Number>("volume") ?: 1.0).toFloat()
                player.volume = v
                result.success(null)
            }
            "setCaption" -> {
                setCaption(call.argument<String>("date"), call.argument<String>("place"))
                result.success(null)
            }
            "open" -> {
                val p = call.argument<String>("path")
                val autoplay = call.argument<Boolean>("autoplay") ?: false
                if (p != null) open(p, autoplay)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
        events = sink
        if (player.playbackState == Player.STATE_READY) {
            send("ready", player.duration)
            send("playing", player.isPlaying)
        }
    }

    override fun onCancel(arguments: Any?) {
        events = null
    }

    override fun dispose() {
        handler.removeCallbacks(ticker)
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        player.release()
    }
}

/**
 * A FrameLayout that lays out its single child at the given [videoAspect]
 * (width / height), scaled down to fit inside the available bounds and
 * centered — i.e. a "contain" fit with letter/pillar-boxing. With aspect 0
 * (unknown) the child simply fills the bounds.
 */
private class AspectFitLayout(context: Context) : FrameLayout(context) {
    var videoAspect: Float = 0f
        set(value) {
            if (field != value) {
                field = value
                requestLayout()
            }
        }

    override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) {
        val child = getChildAt(0) ?: return
        val pw = r - l
        val ph = b - t
        if (videoAspect <= 0f || pw <= 0 || ph <= 0) {
            child.layout(0, 0, pw, ph)
            return
        }
        val viewAspect = pw.toFloat() / ph.toFloat()
        var cw = pw
        var ch = ph
        if (viewAspect > videoAspect) {
            cw = (ph * videoAspect).toInt() // pillarbox: too wide, limit width
        } else {
            ch = (pw / videoAspect).toInt() // letterbox: too tall, limit height
        }
        val left = (pw - cw) / 2
        val top = (ph - ch) / 2
        child.layout(left, top, left + cw, top + ch)
    }
}
