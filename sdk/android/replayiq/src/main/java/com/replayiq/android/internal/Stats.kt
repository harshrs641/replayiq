package com.replayiq.android.internal

import org.json.JSONObject

/**
 * Recording cost counters, logged (debug builds only) so the screenshot and Native DOM modes can be
 * compared: bytes sent, events per subtype, walk / diff times, worst frame. Thread-safe.
 */
internal object Stats {
    private val lock = Any()
    private var since = System.currentTimeMillis()
    private var eventBytesRaw = 0L
    private var eventBytesGzip = 0L
    private var assetBytes = 0L
    private var assetCount = 0
    private val subtypes = HashMap<String, Int>()
    private val walks = Samples()
    private val walkCpu = Samples()
    private val diffs = Samples()
    private var worstFrameMs = 0.0
    private var frames = 0
    private var slowFrames = 0

    fun batch(raw: Int, gzip: Int) = synchronized(lock) { eventBytesRaw += raw; eventBytesGzip += gzip }
    fun asset(bytes: Int) = synchronized(lock) { assetBytes += bytes; assetCount++ }
    fun event(e: JSONObject) {
        val k = e.optString("subtype").ifEmpty { "type" + e.optInt("type") }
        synchronized(lock) { subtypes[k] = (subtypes[k] ?: 0) + 1 }
    }
    fun walk(ns: Long, cpuNs: Long) = synchronized(lock) { walks.add(ns); walkCpu.add(cpuNs) }
    fun diff(ns: Long) = synchronized(lock) { diffs.add(ns) }
    fun frame(ms: Double) = synchronized(lock) {
        frames++
        if (ms > 16.7) slowFrames++
        if (ms > worstFrameMs) worstFrameMs = ms
    }

    fun reset() = synchronized(lock) {
        since = System.currentTimeMillis(); eventBytesRaw = 0; eventBytesGzip = 0; assetBytes = 0; assetCount = 0
        subtypes.clear(); walks.clear(); walkCpu.clear(); diffs.clear(); worstFrameMs = 0.0; frames = 0; slowFrames = 0
    }

    fun summary(mode: String): String = synchronized(lock) {
        val secs = ((System.currentTimeMillis() - since) / 1000.0).coerceAtLeast(1.0)
        val events = subtypes.values.sum()
        String.format(
            java.util.Locale.US,
            "stats mode=%s secs=%.0f events=%d events_per_min=%.0f json_bytes=%d gzip_bytes=%d gzip_per_min=%.0f " +
                "assets=%d asset_bytes=%d walks=%d walk_p50_ms=%.2f walk_p95_ms=%.2f walk_max_ms=%.2f walk_cpu_p50_ms=%.2f walk_cpu_p95_ms=%.2f diff_p50_ms=%.2f diff_p95_ms=%.2f " +
                "frames=%d slow_frames=%d worst_frame_ms=%.1f subtypes=%s",
            mode, secs, events, events * 60 / secs, eventBytesRaw, eventBytesGzip, eventBytesGzip * 60 / secs,
            assetCount, assetBytes, walks.size, walks.pct(50), walks.pct(95), walks.pct(100), walkCpu.pct(50), walkCpu.pct(95), diffs.pct(50), diffs.pct(95),
            frames, slowFrames, worstFrameMs, subtypes.toSortedMap().toString(),
        )
    }

    private class Samples {
        private var a = LongArray(1024)
        var size = 0
            private set
        fun add(v: Long) { if (size == a.size) a = a.copyOf(size * 2); a[size++] = v }
        fun clear() { size = 0 }
        fun pct(p: Int): Double {
            if (size == 0) return 0.0
            val s = a.copyOf(size).also { it.sort() }
            val i = ((p / 100.0) * (size - 1)).toInt().coerceIn(0, size - 1)
            return s[i] / 1_000_000.0
        }
    }
}
