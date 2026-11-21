package com.replayiq.android.internal

import android.annotation.TargetApi
import android.app.Activity
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.drawable.ColorDrawable
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.PixelCopy
import android.view.View
import android.view.ViewTreeObserver
import android.view.Window
import android.view.WindowManager
import com.replayiq.android.ReplayIQOptions
import org.json.JSONObject
import java.lang.ref.WeakReference
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * Native DOM recording (v1.1): walks the current activity's View tree after each draw that
 * changed something (≤ 30 walks/s), then diffs and serialises on the worker thread into
 * `ui_snapshot` / `ui_mutation`. Islands are cropped from a masked PixelCopy of the window, ≤ 2/s.
 */
internal class DomRecorder(
    private val options: ReplayIQOptions,
    private val inspector: ViewInspector,
    private val worker: Handler,
    private val assets: AssetStore,
    private val emit: (JSONObject) -> Unit,
    private val clock: () -> Long = System::currentTimeMillis,
    /** AUTO mode: the current screen is mostly islands (main thread). */
    private val onIslandHeavy: () -> Unit = {},
) {
    private val main = Handler(Looper.getMainLooper())
    private val images = DrawableAssets(assets, worker, IMAGE_JPEG_QUALITY) { markDirty() }
    private val islandHashes = HashMap<Int, String>() // main thread
    private val walker = ViewWalker(options, inspector, images) { islandHashes[it] }
    private val maskPaint = Paint().apply { color = options.maskColor; style = Paint.Style.FILL }

    private var activity: WeakReference<Activity>? = null
    private var observed: WeakReference<View>? = null
    var running = false
        private set
    private var dirty = true
    private var scheduled = false
    private var lastWalkUptime = 0L
    private var forceSnapshot = true
    private var lastSnapshotAt = Long.MIN_VALUE
    private var lastW = -1
    private var lastH = -1

    // Islands (main thread).
    private var lastIslands: List<IslandRef> = emptyList()
    private var lastIslandUptime = 0L
    private var islandInFlight = false
    private var islandDeferred = false

    // Worker thread.
    private val differ = DomDiffer()
    private val lastIslandFrame = HashMap<Int, String>()
    private class PendingScroll(val selector: String, val x: Float, val y: Float, val at: Long)
    private val scrolls = HashMap<Int, PendingScroll>()

    private val onDraw = ViewTreeObserver.OnDrawListener { markDirty() }
    private val walkTask = Runnable {
        scheduled = false
        if (!running || !dirty) return@Runnable
        dirty = false
        try { walk() } catch (t: Throwable) { Log.w("DOM walk failed", t) }
    }
    private val islandTask = Runnable { islandDeferred = false; captureIslands() }
    private val scrollCheck = Runnable { emitSettledScrolls() }

    /** Main thread. */
    fun setActivity(a: Activity?) {
        if (activity?.get() === a) return
        detach()
        activity = a?.let { WeakReference(it) }
        islandHashes.clear()
        requestSnapshot()
    }

    fun start() {
        if (running) return
        running = true
        requestSnapshot()
    }

    fun stop() {
        running = false
        main.removeCallbacks(walkTask)
        main.removeCallbacks(islandTask)
        scheduled = false
        detach()
    }

    /** The next walk sends a full `ui_snapshot` (screen change, resume, new session, mode switch). */
    fun requestSnapshot() {
        forceSnapshot = true
        markDirty()
    }

    fun newSession() {
        worker.post { differ.reset() }
        requestSnapshot()
    }

    private fun markDirty() {
        dirty = true
        schedule()
    }

    private fun schedule() {
        if (!running || scheduled) return
        scheduled = true
        val wait = max(0L, lastWalkUptime + MIN_WALK_INTERVAL_MS - SystemClock.uptimeMillis())
        main.postDelayed(walkTask, wait)
    }

    private fun detach() {
        observed?.get()?.viewTreeObserver?.let { if (it.isAlive) it.removeOnDrawListener(onDraw) }
        observed = null
    }

    private fun ensureListener(decor: View) {
        if (observed?.get() === decor) return
        detach()
        val vto = decor.viewTreeObserver
        if (!vto.isAlive) return
        vto.addOnDrawListener(onDraw)
        observed = WeakReference(decor)
    }

    private fun walk() {
        val a = activity?.get() ?: return
        if (a.isFinishing) return
        val window = a.window ?: return
        val decor = window.peekDecorView()
        if (decor == null || !decor.isAttachedToWindow || decor.width <= 0 || decor.height <= 0) {
            // Right after onResume the window isn't attached yet: try again shortly.
            dirty = true
            if (!scheduled) { scheduled = true; main.postDelayed(walkTask, NOT_READY_RETRY_MS) }
            return
        }
        ensureListener(decor)
        lastWalkUptime = SystemClock.uptimeMillis()

        val t0 = System.nanoTime()
        val c0 = android.os.Debug.threadCpuTimeNanos()
        val result = walker.walk(decor)
        val walkNs = System.nanoTime() - t0
        val cpuNs = android.os.Debug.threadCpuTimeNanos() - c0
        Stats.walk(walkNs, cpuNs)
        if (walkNs > SLOW_WALK_NS) Log.d("slow walk: ${walkNs / 1_000_000} ms (cpu ${cpuNs / 1_000_000} ms), ${result.nodes} views, ${a.javaClass.simpleName}")

        val now = clock()
        val density = decor.resources.displayMetrics.density
        val wDp = max(1, (decor.width / density).roundToInt())
        val hDp = max(1, (decor.height / density).roundToInt())
        val snapshot = forceSnapshot || wDp != lastW || hDp != lastH || now - lastSnapshotAt >= SNAPSHOT_INTERVAL_MS
        if (snapshot) { forceSnapshot = false; lastSnapshotAt = now }
        lastW = wDp; lastH = hDp
        val bg = (decor.background as? ColorDrawable)?.color ?: 0xFFFFFFFF.toInt()

        worker.post { process(result.root, snapshot, now, wDp, hDp, density, bg) }
        if (walker.incomplete) markDirty()

        val secure = window.attributes.flags and WindowManager.LayoutParams.FLAG_SECURE != 0
        lastIslands = if (secure) emptyList() else result.islands
        if (lastIslands.isNotEmpty()) captureIslands()
        if (options.recordingMode == ReplayIQOptions.RecordingMode.AUTO && result.screenArea > 0 &&
            result.islandArea / result.screenArea > ISLAND_HEAVY_FRACTION) {
            onIslandHeavy()
        }
    }

    // ------------------------------------------------------------------ worker: diff + serialise

    private fun process(root: DomNode, snapshot: Boolean, ts: Long, w: Int, h: Int, density: Float, bg: Int) {
        try {
            val t0 = System.nanoTime()
            var ev: JSONObject? = null
            if (!snapshot && differ.hasBaseline) {
                val m = differ.mutation(root)
                if (m != null) {
                    if (!m.isEmpty) {
                        ev = JSONObject().put("type", 5).put("subtype", "ui_mutation").put("timestamp", ts)
                        if (m.adds.length() > 0) ev.put("adds", m.adds)
                        if (m.removes.length() > 0) ev.put("removes", m.removes)
                        if (m.updates.length() > 0) ev.put("updates", m.updates)
                    }
                    for (s in differ.scrolled) {
                        val so = s.so ?: continue
                        scrolls[s.id] = PendingScroll(s.selector ?: "scroll:\"Scroll\"", so[0], so[1], ts)
                    }
                    if (differ.scrolled.isNotEmpty()) { worker.removeCallbacks(scrollCheck); worker.postDelayed(scrollCheck, SCROLL_SETTLE_MS + 50) }
                    Stats.diff(System.nanoTime() - t0)
                    ev?.let(emit)
                    return
                }
            }
            val json = differ.snapshot(root)
            ev = JSONObject().put("type", 5).put("subtype", "ui_snapshot").put("timestamp", ts)
                .put("width", w).put("height", h).put("density", DomNode.r2(density))
                .put("bg", DomNode.color(bg)).put("root", json)
            Stats.diff(System.nanoTime() - t0)
            emit(ev)
        } catch (t: Throwable) {
            Log.w("DOM diff failed", t)
            differ.reset()
            main.post { requestSnapshot() }
        }
    }

    private fun emitSettledScrolls() {
        val now = clock()
        val it = scrolls.entries.iterator()
        while (it.hasNext()) {
            val (_, s) = it.next()
            if (now - s.at >= SCROLL_SETTLE_MS) {
                emit(Events.scroll(now, s.selector, s.x, s.y))
                it.remove()
            }
        }
        if (scrolls.isNotEmpty()) worker.postDelayed(scrollCheck, SCROLL_SETTLE_MS)
    }

    // ------------------------------------------------------------------ islands

    private fun captureIslands() {
        if (!running || lastIslands.isEmpty() || Build.VERSION.SDK_INT < 26) return
        val now = SystemClock.uptimeMillis()
        if (islandInFlight || now - lastIslandUptime < ISLAND_INTERVAL_MS) {
            if (!islandDeferred) {
                islandDeferred = true
                main.postDelayed(islandTask, max(50L, lastIslandUptime + ISLAND_INTERVAL_MS - now))
            }
            return
        }
        val a = activity?.get() ?: return
        val window = a.window ?: return
        val decor = window.peekDecorView() ?: return
        if (!decor.isAttachedToWindow || decor.width <= 0 || decor.height <= 0) return
        lastIslandUptime = now
        val density = decor.resources.displayMetrics.density
        val scale = options.imageScale / density
        val masks = ArrayList<Rect>()
        try { inspector.collectMasks(decor, masks) } catch (t: Throwable) { Log.d("masks failed: $t"); return }
        val islands = lastIslands
        val inWindow = islands.filter { it.surface == null }
        if (inWindow.isNotEmpty()) {
            val bmp = Bitmap.createBitmap(max(1, ceil(decor.width * scale).toInt()), max(1, ceil(decor.height * scale).toInt()), Bitmap.Config.ARGB_8888)
            islandInFlight = true
            copyWindow(window, bmp) { ok ->
                try { if (ok) cropIslands(bmp, inWindow, masks, scale) } finally { bmp.recycle(); main.post { islandInFlight = false } }
            }
        }
        for (s in islands) {
            val sv = s.surface ?: continue
            val bmp = Bitmap.createBitmap(max(1, ceil(sv.width * scale).toInt()), max(1, ceil(sv.height * scale).toInt()), Bitmap.Config.ARGB_8888)
            copySurface(sv, bmp) { ok -> try { if (ok) publishIsland(s.id, bmp) } finally { bmp.recycle() } }
        }
    }

    @TargetApi(26)
    private fun copyWindow(window: Window, bmp: Bitmap, done: (Boolean) -> Unit) {
        try {
            PixelCopy.request(window, bmp, { done(it == PixelCopy.SUCCESS) }, worker)
        } catch (t: Throwable) { Log.d("island copy failed: $t"); bmp.recycle(); islandInFlight = false }
    }

    @TargetApi(24)
    private fun copySurface(sv: android.view.SurfaceView, bmp: Bitmap, done: (Boolean) -> Unit) {
        try {
            PixelCopy.request(sv, bmp, { done(it == PixelCopy.SUCCESS) }, worker)
        } catch (t: Throwable) { Log.d("surface copy failed: $t"); bmp.recycle() }
    }

    /** Worker thread. */
    private fun cropIslands(bmp: Bitmap, islands: List<IslandRef>, masks: List<Rect>, scale: Float) {
        if (masks.isNotEmpty()) {
            val c = Canvas(bmp)
            for (m in masks) c.drawRect(m.left * scale - 1, m.top * scale - 1, m.right * scale + 1, m.bottom * scale + 1, maskPaint)
        }
        for (isl in islands) {
            val l = (isl.rect.left * scale).roundToInt().coerceIn(0, bmp.width)
            val t = (isl.rect.top * scale).roundToInt().coerceIn(0, bmp.height)
            val r = (isl.rect.right * scale).roundToInt().coerceIn(0, bmp.width)
            val b = (isl.rect.bottom * scale).roundToInt().coerceIn(0, bmp.height)
            if (r - l < 2 || b - t < 2) continue
            // Partly off-screen: keep the last full frame rather than send a squashed one.
            if (r - l < (isl.rect.width() * scale).roundToInt() - 2 || b - t < (isl.rect.height() * scale).roundToInt() - 2) continue
            val crop = Bitmap.createBitmap(bmp, l, t, r - l, b - t)
            try { publishIsland(isl.id, crop) } finally { if (crop !== bmp) crop.recycle() }
        }
    }

    /** Worker thread: uploads a changed island frame and points the node at it. */
    private fun publishIsland(id: Int, bmp: Bitmap) {
        val out = java.io.ByteArrayOutputStream(8 * 1024)
        bmp.compress(Bitmap.CompressFormat.JPEG, options.jpegQuality, out)
        val bytes = out.toByteArray()
        val hash = AssetStore.sha256(bytes)
        if (lastIslandFrame[id] == hash) return
        lastIslandFrame[id] = hash
        assets.register(hash, "image/jpeg", bytes)
        main.post { islandHashes[id] = hash; markDirty() }
    }

    private companion object {
        const val MIN_WALK_INTERVAL_MS = 33L       // ≤ 30 walks / mutations per second
        const val SNAPSHOT_INTERVAL_MS = 30_000L
        const val ISLAND_INTERVAL_MS = 500L        // ≤ 2 island captures per second
        const val ISLAND_HEAVY_FRACTION = 0.5f
        const val SCROLL_SETTLE_MS = 300L
        const val IMAGE_JPEG_QUALITY = 80
        const val NOT_READY_RETRY_MS = 100L
        const val SLOW_WALK_NS = 8_000_000L
    }
}
