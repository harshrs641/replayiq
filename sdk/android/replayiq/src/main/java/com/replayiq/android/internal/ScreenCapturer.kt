package com.replayiq.android.internal

import android.app.Activity
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.RectF
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Base64
import android.view.PixelCopy
import android.view.View
import android.view.ViewTreeObserver
import android.view.WindowManager
import android.annotation.TargetApi
import com.replayiq.android.ReplayIQOptions
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.lang.ref.WeakReference
import java.util.zip.CRC32
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * Screenshots of the current activity window, at most [ReplayIQOptions.maxFps], only after the
 * window redrew, masked before encoding. Mask rects are found on the main thread; the pixels are
 * copied by PixelCopy (API 26+, off the main thread) or View.draw (API 24–25); masking, JPEG and
 * base64 run on the worker thread.
 */
internal class ScreenCapturer(
    private val options: ReplayIQOptions,
    private val inspector: ViewInspector,
    private val worker: Handler,
    private val emit: (JSONObject) -> Unit,
    private val clock: () -> Long = System::currentTimeMillis,
) {
    private val main = Handler(Looper.getMainLooper())
    private val intervalMs = (1000.0 / options.maxFps).roundToInt().toLong()
    private val keyframes = KeyframePolicy()
    private val maskPaint = Paint().apply { color = options.maskColor; style = Paint.Style.FILL }

    private var activity: WeakReference<Activity>? = null
    private var observed: WeakReference<View>? = null
    private var running = false
    @Volatile private var dirty = true
    private var inFlightSince = 0L
    private var lastScrollAt = 0L

    // Worker thread only.
    private var lastCrc = -1L

    private val onDraw = ViewTreeObserver.OnDrawListener { dirty = true }
    private val onScroll = ViewTreeObserver.OnScrollChangedListener { lastScrollAt = clock(); dirty = true }
    private val tick = object : Runnable {
        override fun run() {
            if (!running) return
            try { capture() } catch (t: Throwable) { Log.w("capture failed", t); inFlightSince = 0 }
            main.postDelayed(this, intervalMs)
        }
    }

    /** Main thread. */
    fun setActivity(a: Activity?) {
        if (activity?.get() === a) return
        detachListeners()
        activity = a?.let { WeakReference(it) }
        dirty = true
    }

    /** Main thread. */
    fun start() {
        if (running) return
        running = true
        dirty = true
        main.post(tick)
    }

    /** Main thread. */
    fun stop() {
        running = false
        main.removeCallbacks(tick)
        detachListeners()
    }

    /** Main thread: the next frame starts a new session, so it must be a keyframe. */
    fun newSession() {
        keyframes.reset()
        dirty = true
        worker.post { lastCrc = -1 }
    }

    private fun detachListeners() {
        observed?.get()?.viewTreeObserver?.let { vto ->
            if (vto.isAlive) { vto.removeOnDrawListener(onDraw); vto.removeOnScrollChangedListener(onScroll) }
        }
        observed = null
    }

    private fun ensureListeners(decor: View) {
        if (observed?.get() === decor) return
        detachListeners()
        val vto = decor.viewTreeObserver
        if (!vto.isAlive) return
        vto.addOnDrawListener(onDraw)
        vto.addOnScrollChangedListener(onScroll)
        observed = WeakReference(decor)
        dirty = true
    }

    private fun capture() {
        val a = activity?.get() ?: return
        if (a.isFinishing) return
        val window = a.window ?: return
        val decor = window.peekDecorView() ?: return
        if (!decor.isAttachedToWindow || decor.width <= 0 || decor.height <= 0) return
        ensureListeners(decor)

        val now = clock()
        if (inFlightSince != 0L) {
            if (now - inFlightSince < 3000) return
            inFlightSince = 0 // a PixelCopy that never called back
        }
        val density = decor.resources.displayMetrics.density
        val wDp = max(1, (decor.width / density).roundToInt())
        val hDp = max(1, (decor.height / density).roundToInt())
        val keyframe = keyframes.needsKeyframe(now, wDp, hDp)
        if (!dirty && !keyframe) return

        val masks = ArrayList<Rect>()
        inspector.collectMasks(decor, masks)
        // Mid-scroll the copied pixels can lag the view positions by a frame: wait until it settles
        // rather than risk a mask landing next to the field it should cover.
        if (masks.isNotEmpty() && now - lastScrollAt < SCROLL_SETTLE_MS) { dirty = true; return }
        dirty = false

        val outW = max(1, (wDp * options.imageScale).roundToInt())
        val outH = max(1, (hDp * options.imageScale).roundToInt())
        val sx = outW.toFloat() / decor.width
        val sy = outH.toFloat() / decor.height
        val secure = window.attributes.flags and WindowManager.LayoutParams.FLAG_SECURE != 0
        val bitmap = Bitmap.createBitmap(outW, outH, Bitmap.Config.ARGB_8888)
        val frame = Frame(now, wDp, hDp, keyframe, bitmap, masks, sx, sy)
        keyframes.sent(now, wDp, hDp, keyframe)
        inFlightSince = now

        when {
            // FLAG_SECURE: the app asked for this window never to be captured. Send a blank frame.
            secure -> worker.post { bitmap.eraseColor(options.maskColor); frame.masks.clear(); encode(frame) }
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.O -> pixelCopy(window, frame)
            else -> {
                val c = Canvas(bitmap)
                c.scale(sx, sy)
                decor.draw(c)
                worker.post { encode(frame) }
            }
        }
    }

    @TargetApi(Build.VERSION_CODES.O)
    private fun pixelCopy(window: android.view.Window, frame: Frame) {
        PixelCopy.request(window, frame.bitmap, { result ->
            if (result == PixelCopy.SUCCESS) {
                encode(frame)
            } else {
                Log.d("PixelCopy failed: $result")
                frame.bitmap.recycle()
                main.post { inFlightSince = 0; dirty = true; if (frame.keyframe) keyframes.reset() }
            }
        }, worker)
    }

    /** Worker thread. */
    private fun encode(frame: Frame) {
        try {
            val bmp = frame.bitmap
            if (frame.masks.isNotEmpty()) {
                val c = Canvas(bmp)
                val r = RectF()
                for (m in frame.masks) {
                    r.set(m.left * frame.sx, m.top * frame.sy, m.right * frame.sx, m.bottom * frame.sy)
                    r.inset(-MASK_PAD_PX, -MASK_PAD_PX)
                    c.drawRect(r, maskPaint)
                }
            }
            val out = ByteArrayOutputStream(32 * 1024)
            bmp.compress(Bitmap.CompressFormat.JPEG, options.jpegQuality, out)
            val bytes = out.toByteArray()
            val crc = CRC32().apply { update(bytes) }.value
            if (!frame.keyframe && crc == lastCrc) return // redrawn but identical (cursor blink under a mask, ...)
            lastCrc = crc
            if (bytes.size > MAX_FRAME_BYTES) { Log.w("frame too large (${bytes.size} B), skipped"); return }
            val dataUrl = "data:image/jpeg;base64," + Base64.encodeToString(bytes, Base64.NO_WRAP)
            emit(Events.screen(frame.ts, frame.wDp, frame.hDp, dataUrl, frame.keyframe))
        } catch (t: Throwable) {
            Log.w("encode failed", t)
            if (frame.keyframe) main.post { keyframes.reset() }
        } finally {
            frame.bitmap.recycle()
            main.post { inFlightSince = 0 }
        }
    }

    private class Frame(
        val ts: Long, val wDp: Int, val hDp: Int, val keyframe: Boolean,
        val bitmap: Bitmap, val masks: MutableList<Rect>, val sx: Float, val sy: Float,
    )

    private companion object {
        const val SCROLL_SETTLE_MS = 150L
        const val MASK_PAD_PX = 1f
        const val MAX_FRAME_BYTES = 1_400_000 // base64 grows it by 4/3; one event must stay < 2 MB
    }
}
