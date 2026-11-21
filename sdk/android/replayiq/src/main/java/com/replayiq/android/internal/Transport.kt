package com.replayiq.android.internal

import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong
import java.util.zip.GZIPOutputStream

/** What to do with a request after the server answered (the spec's "Errors and retries" table). */
internal sealed class Outcome {
    object Done : Outcome()            // 2xx
    object Drop : Outcome()            // 400 (and other 4xx): retrying won't help
    object Stop : Outcome()            // 401/403: stop recording for this run
    object Split : Outcome()           // 413
    data class Retry(val delayMs: Long) : Outcome()
}

internal object RetryPolicy {
    const val MAX_BACKOFF_MS = 60_000L

    /** 1 s, 2 s, 4 s ... capped at 60 s. [attempt] counts from 0. */
    fun backoffMs(attempt: Int): Long = (1000L shl attempt.coerceIn(0, 6)).coerceAtMost(MAX_BACKOFF_MS)

    /** [status] -1 = network error (no response). */
    fun decide(status: Int, retryAfterSeconds: Long?, attempt: Int): Outcome = when {
        status in 200..299 -> Outcome.Done
        status == 401 || status == 403 -> Outcome.Stop
        status == 413 -> Outcome.Split
        status == 429 -> Outcome.Retry(
            retryAfterSeconds?.let { (it * 1000).coerceIn(1000, 10 * 60_000L) } ?: backoffMs(attempt)
        )
        status in 400..499 -> Outcome.Drop
        else -> Outcome.Retry(backoffMs(attempt)) // 5xx, network error, anything odd
    }
}

/**
 * Requests persisted to disk until the server accepts them: survives app kills, keeps order (FIFO
 * by file name) and the batch_id of each batch. Each file is `<path>\n<json body>`.
 */
internal class DiskQueue(private val dir: File) {
    private val counter: AtomicLong

    init {
        dir.mkdirs()
        // Names must keep sorting after files left by an earlier run, even if the clock went back.
        val newest = files().lastOrNull()?.name?.take(19)?.toLongOrNull() ?: 0L
        counter = AtomicLong(maxOf(System.currentTimeMillis() * 1000, newest + 1))
    }

    data class Item(val file: File, val path: String, val body: String) {
        val isEvents get() = path == EVENTS_PATH
    }

    @Synchronized
    fun add(path: String, body: String): File {
        val name = String.format(java.util.Locale.US, "%019d", counter.incrementAndGet())
        val tmp = File(dir, "$name.tmp")
        tmp.writeText(path + "\n" + body)
        val f = File(dir, "$name.req")
        tmp.renameTo(f)
        trim()
        return f
    }

    @Synchronized
    fun files(): List<File> = (dir.listFiles { f -> f.name.endsWith(".req") } ?: emptyArray()).sortedBy { it.name }

    fun oldest(): Item? {
        for (f in files()) {
            val item = read(f)
            if (item != null) return item
            f.delete() // unreadable: drop it
        }
        return null
    }

    private fun read(f: File): Item? = try {
        val text = f.readText()
        val nl = text.indexOf('\n')
        if (nl <= 0) null else Item(f, text.substring(0, nl), text.substring(nl + 1))
    } catch (_: IOException) {
        null
    }

    @Synchronized
    fun remove(item: Item) { item.file.delete() }

    /** Replaces [item] with two halves of its events, in place (names sort right after the original). */
    @Synchronized
    fun split(item: Item): Boolean {
        val body = JSONObject(item.body)
        val events = body.optJSONArray("events") ?: JSONArray()
        val custom = body.optJSONArray("custom_events") ?: JSONArray()
        if (events.length() + custom.length() < 2) { item.file.delete(); return false }
        val batchId = body.optString("batch_id")
        val base = item.file.name.removeSuffix(".req")
        fun half(from: Int, to: Int, suffix: String, withCustom: Boolean) {
            val part = JSONObject(item.body)
            val ev = JSONArray(); for (i in from until to) ev.put(events.get(i))
            part.put("events", ev)
            if (withCustom) part.put("custom_events", custom) else part.remove("custom_events")
            part.put("batch_id", "$batchId-$suffix")
            File(dir, "$base-$suffix.req").writeText(item.path + "\n" + part.toString())
        }
        val mid = events.length() / 2
        if (events.length() >= 2) {
            half(0, mid, "a", withCustom = true)
            half(mid, events.length(), "b", withCustom = false)
        } else {
            // One event plus custom events: send them separately.
            half(0, events.length(), "a", withCustom = false)
            val part = JSONObject(item.body).put("events", JSONArray()).put("custom_events", custom).put("batch_id", "$batchId-b")
            File(dir, "$base-b.req").writeText(item.path + "\n" + part.toString())
        }
        item.file.delete()
        return true
    }

    @Synchronized
    fun clear() { files().forEach { it.delete() } }

    /** Keeps at most ~5 MB / ~1000 events of event batches, dropping the oldest. Session create/end are kept. */
    private fun trim() {
        val all = files()
        var bytes = all.sumOf { it.length() }
        val eventFiles = all.filter { f -> f.length() > 0 && firstLine(f) == EVENTS_PATH }.toMutableList()
        while ((bytes > MAX_BYTES || eventFiles.size > MAX_EVENT_FILES) && eventFiles.size > 1) {
            val f = eventFiles.removeAt(0)
            bytes -= f.length()
            f.delete()
            Log.d("queue full: dropped ${f.name}")
        }
    }

    private fun firstLine(f: File): String? = try {
        f.bufferedReader().use { it.readLine() }
    } catch (_: IOException) { null }

    companion object {
        const val EVENTS_PATH = "/api/v1/events"
        const val MAX_BYTES = 5L * 1024 * 1024
        const val MAX_EVENT_FILES = 20 // batches hold ≤ 50 events → ≤ 1000 events
    }
}

/** HTTP POST of one request: gzip body, Bearer key. Returns the status (-1 on network error) and Retry-After. */
internal fun interface HttpSender {
    fun post(url: String, key: String, gzipBody: ByteArray): Pair<Int, Long?>

    /** An asset request (v1.1 §3): `HEAD <url>` when [body] is null, else a raw `POST`. */
    fun asset(url: String, key: String, hash: String, contentType: String, body: ByteArray?): Pair<Int, Long?> =
        UrlConnectionSender.assetRequest(url, key, hash, contentType, body)
}

internal object UrlConnectionSender : HttpSender {
    fun assetRequest(url: String, key: String, hash: String, contentType: String, body: ByteArray?): Pair<Int, Long?> {
        var conn: HttpURLConnection? = null
        return try {
            conn = (URL(url).openConnection() as HttpURLConnection).apply {
                requestMethod = if (body == null) "HEAD" else "POST"
                connectTimeout = 10_000
                readTimeout = 20_000
                useCaches = false
                setRequestProperty("Authorization", "Bearer $key")
                if (body != null) {
                    doOutput = true
                    setFixedLengthStreamingMode(body.size)
                    setRequestProperty("Content-Type", contentType)
                    setRequestProperty("X-Asset-Hash", hash)
                }
            }
            if (body != null) conn.outputStream.use { it.write(body) }
            val code = conn.responseCode
            val retryAfter = conn.getHeaderField("Retry-After")?.trim()?.toLongOrNull()
            try { (if (code >= 400) conn.errorStream else conn.inputStream)?.use { it.readBytes() } } catch (_: IOException) {}
            code to retryAfter
        } catch (e: IOException) {
            Log.d("network error: ${e.message}")
            -1 to null
        } finally {
            conn?.disconnect()
        }
    }

    override fun post(url: String, key: String, gzipBody: ByteArray): Pair<Int, Long?> {
        var conn: HttpURLConnection? = null
        return try {
            conn = (URL(url).openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"
                connectTimeout = 10_000
                readTimeout = 20_000
                doOutput = true
                useCaches = false
                setFixedLengthStreamingMode(gzipBody.size)
                setRequestProperty("Content-Type", "application/json")
                setRequestProperty("Content-Encoding", "gzip")
                setRequestProperty("Authorization", "Bearer $key")
            }
            conn.outputStream.use { it.write(gzipBody) }
            val code = conn.responseCode
            val retryAfter = conn.getHeaderField("Retry-After")?.trim()?.toLongOrNull()
            try { (if (code >= 400) conn.errorStream else conn.inputStream)?.use { it.readBytes() } } catch (_: IOException) {}
            code to retryAfter
        } catch (e: IOException) {
            Log.d("network error: ${e.message}")
            -1 to null
        } finally {
            conn?.disconnect()
        }
    }
}

internal fun gzip(text: String): ByteArray {
    val out = ByteArrayOutputStream(text.length / 4 + 64)
    GZIPOutputStream(out).use { it.write(text.toByteArray(Charsets.UTF_8)) }
    return out.toByteArray()
}

/** Sends the disk queue in order on its own thread, applying [RetryPolicy]. */
internal class Uploader(
    private val queue: DiskQueue,
    private val endpoint: String,
    private val key: String,
    private val sender: HttpSender = UrlConnectionSender,
    private val onStop: () -> Unit,
    private val assets: AssetStore? = null,
    private val executor: ScheduledExecutorService = Executors.newSingleThreadScheduledExecutor { r ->
        Thread(r, "ReplayIQ-upload").apply { isDaemon = true; priority = Thread.MIN_PRIORITY }
    },
) {
    private var attempt = 0
    private var pending: ScheduledFuture<*>? = null
    @Volatile private var stopped = false
    @Volatile private var loggedDrop = false

    /** Start sending now unless a backoff wait is in progress. */
    fun kick() {
        if (stopped) return
        synchronized(this) {
            if (pending != null) return
            pending = executor.schedule({ drain() }, 0, TimeUnit.MILLISECONDS)
        }
    }

    /** Ignore backoff and send now (e.g. app went to background, or the network came back). */
    fun kickNow() {
        if (stopped) return
        synchronized(this) {
            pending?.cancel(false)
            pending = executor.schedule({ drain() }, 0, TimeUnit.MILLISECONDS)
        }
    }

    fun stop() { stopped = true }

    /** Runs [block] on the upload thread after what is already queued. */
    fun execute(block: () -> Unit) { executor.execute(block) }

    private fun drain() {
        synchronized(this) { pending = null }
        while (!stopped) {
            val item = queue.oldest() ?: return
            val isAsset = item.path == AssetStore.PATH
            var hash: String? = null
            val (status, retryAfter) = try {
                if (isAsset) {
                    val meta = JSONObject(item.body)
                    hash = meta.getString("hash")
                    sendAsset(hash, meta.optString("type", "image/png"))
                } else {
                    val gz = gzip(item.body)
                    if (item.isEvents) Stats.batch(item.body.length, gz.size)
                    sender.post(endpoint + item.path, key, gz)
                }
            } catch (t: Throwable) {
                Log.w("send failed", t); -1 to null
            }
            when (val o = RetryPolicy.decide(status, retryAfter, attempt)) {
                Outcome.Done -> { attempt = 0; queue.remove(item); hash?.let { assets?.markSent(it) } }
                Outcome.Drop -> {
                    attempt = 0; queue.remove(item); hash?.let { assets?.drop(it) }
                    if (!loggedDrop) { loggedDrop = true; Log.w("server rejected ${item.path} ($status); dropped") }
                }
                Outcome.Split -> {
                    attempt = 0
                    if (isAsset) { queue.remove(item); hash?.let { assets?.drop(it) } }
                    else if (!queue.split(item)) Log.w("event too large; dropped")
                }
                Outcome.Stop -> {
                    Log.w("ingest key rejected ($status): recording stopped for this run")
                    stopped = true
                    queue.clear()
                    onStop()
                    return
                }
                is Outcome.Retry -> {
                    attempt++
                    Log.d("retry ${item.path} in ${o.delayMs} ms (status $status)")
                    synchronized(this) { pending = executor.schedule({ drain() }, o.delayMs, TimeUnit.MILLISECONDS) }
                    return
                }
            }
        }
    }

    /** HEAD first (the server may have it from another session or install), then POST the bytes. */
    private fun sendAsset(hash: String, type: String): Pair<Int, Long?> {
        val head = sender.asset("$endpoint${AssetStore.PATH}/$hash", key, hash, type, null)
        if (head.first == 200) return head
        if (head.first != 404) return head
        val blob = assets?.blob(hash)
        if (blob == null || !blob.exists()) return 400 to null // nothing to send: drop
        return sender.asset("$endpoint${AssetStore.PATH}", key, hash, type, blob.readBytes())
    }
}
