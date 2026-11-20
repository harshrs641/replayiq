package com.replayiq.android.internal

import android.graphics.Bitmap
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import android.os.Handler
import android.os.Looper
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.security.MessageDigest

/**
 * Assets (recording API v1.1 §3): each image / island frame / font is uploaded once, by sha256.
 * Registering an asset writes its bytes to disk and puts an upload request in the same FIFO
 * [DiskQueue] as the batches, so it is sent before any batch that references it. Hashes the
 * server has are remembered on disk. Thread-safe.
 */
internal class AssetStore(private val dir: File, private val queue: DiskQueue) {
    private val blobs = File(dir, "blobs").apply { mkdirs() }
    private val knownFile = File(dir, "known.txt")
    private val known = HashSet<String>()
    private val queued = HashSet<String>()

    init {
        try { if (knownFile.exists()) knownFile.forEachLine { if (it.length == 64) known.add(it) } } catch (_: Exception) {}
        // Uploads still queued from an earlier run.
        blobs.listFiles()?.forEach { queued.add(it.name) }
    }

    /** Queues an upload unless the server has it or it's queued. Returns false when skipped. */
    @Synchronized
    fun register(hash: String, type: String, bytes: ByteArray): Boolean {
        if (hash in known || hash in queued) return false
        if (bytes.size > MAX_BYTES) { Log.d("asset too large (${bytes.size} B), skipped"); return false }
        File(blobs, hash).writeBytes(bytes)
        queue.add(PATH, JSONObject().put("hash", hash).put("type", type).toString())
        queued.add(hash)
        Stats.asset(bytes.size)
        return true
    }

    @Synchronized
    fun markSent(hash: String) {
        queued.remove(hash)
        File(blobs, hash).delete()
        if (known.add(hash)) try { knownFile.appendText(hash + "\n") } catch (_: Exception) {}
    }

    @Synchronized
    fun drop(hash: String) { queued.remove(hash); File(blobs, hash).delete() }

    fun blob(hash: String): File = File(blobs, hash)

    @Synchronized
    fun clearQueued() { queued.clear(); blobs.listFiles()?.forEach { it.delete() } }

    companion object {
        const val PATH = "/api/v1/assets"
        const val MAX_BYTES = 2 * 1024 * 1024 - 1024

        fun sha256(bytes: ByteArray): String {
            val d = MessageDigest.getInstance("SHA-256").digest(bytes)
            val sb = StringBuilder(64)
            for (b in d) { val v = b.toInt() and 0xff; sb.append(HEX[v ushr 4]).append(HEX[v and 15]) }
            return sb.toString()
        }

        private val HEX = "0123456789abcdef".toCharArray()

        /** PNG when the bitmap has transparency, else JPEG. Returns (bytes, content type). */
        fun encode(bmp: Bitmap, jpegQuality: Int): Pair<ByteArray, String> {
            val out = ByteArrayOutputStream(16 * 1024)
            return if (bmp.hasAlpha() && hasTransparentPixel(bmp)) {
                bmp.compress(Bitmap.CompressFormat.PNG, 100, out); out.toByteArray() to "image/png"
            } else {
                bmp.compress(Bitmap.CompressFormat.JPEG, jpegQuality, out); out.toByteArray() to "image/jpeg"
            }
        }

        private fun hasTransparentPixel(bmp: Bitmap): Boolean {
            val w = bmp.width; val h = bmp.height
            val stepX = maxOf(1, w / 16); val stepY = maxOf(1, h / 16)
            var y = 0
            while (y < h) {
                var x = 0
                while (x < w) { if (bmp.getPixel(x, y) ushr 24 != 0xff) return true; x += stepX }
                y += stepY
            }
            return bmp.getPixel(w - 1, h - 1) ushr 24 != 0xff
        }
    }
}

/**
 * Drawables (ImageView content, backgrounds the DOM can't describe) as assets: rasterised once per
 * look on the main thread (≤ 1x: one pixel per dp), encoded and hashed on the worker. Until the
 * hash is known the node has no `img`; [onReady] asks for another walk when it is.
 */
internal class DrawableAssets(
    private val assets: AssetStore,
    private val worker: Handler,
    private val jpegQuality: Int,
    private val onReady: () -> Unit,
) {
    private val main = Handler(Looper.getMainLooper())

    private data class Key(val identity: Int, val gen: Int, val w: Int, val h: Int, val state: Int, val level: Int, val alpha: Int)

    private val cache = object : LinkedHashMap<Key, String>(64, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<Key, String>?) = size > 512
    }
    private val pending = HashSet<Key>()
    private var budget = 0

    /** Called at the start of each walk: limits rasterising per walk so a walk stays cheap. */
    fun newWalk() { budget = MAX_PER_WALK }

    /**
     * Hash of [d] laid out at [w]x[h] px, drawn at [tw]x[th] (dp); null while it's being prepared.
     */
    fun hashFor(d: Drawable, w: Int, h: Int, tw: Int, th: Int): String? {
        if (tw <= 0 || th <= 0) return null
        val identity: Int
        val gen: Int
        if (d is BitmapDrawable && d.bitmap != null) {
            identity = System.identityHashCode(d.bitmap); gen = d.bitmap.generationId
        } else {
            identity = System.identityHashCode(d.constantState ?: d); gen = 0
        }
        val key = Key(identity, gen, tw, th, d.state.contentHashCode(), d.level, d.alpha)
        cache[key]?.let { return it }
        if (key in pending || budget <= 0) return null
        budget--
        val bmp = try { Drawables.rasterize(d, w, h, tw, th) } catch (t: Throwable) { Log.d("rasterize failed: $t"); null } ?: return null
        pending.add(key)
        worker.post {
            var hash: String? = null
            try {
                val (bytes, type) = AssetStore.encode(bmp, jpegQuality)
                hash = AssetStore.sha256(bytes)
                assets.register(hash, type, bytes)
            } catch (t: Throwable) {
                Log.d("encode failed: $t")
            } finally {
                bmp.recycle()
            }
            main.post {
                pending.remove(key)
                if (hash != null) { cache[key] = hash; onReady() }
            }
        }
        return null
    }

    private companion object { const val MAX_PER_WALK = 4 }
}
