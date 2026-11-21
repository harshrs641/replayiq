package com.replayiq.android.internal

import kotlin.math.hypot

/** Keyframe rules: first frame of the session, every size change, and at least every 30 s. */
internal class KeyframePolicy(private val intervalMs: Long = 30_000) {
    private var lastKeyframeAt = Long.MIN_VALUE
    private var lastW = -1
    private var lastH = -1

    fun needsKeyframe(now: Long, w: Int, h: Int): Boolean =
        lastKeyframeAt == Long.MIN_VALUE || w != lastW || h != lastH || now - lastKeyframeAt >= intervalMs

    fun sent(now: Long, w: Int, h: Int, keyframe: Boolean) {
        if (keyframe) lastKeyframeAt = now
        lastW = w; lastH = h
    }

    /** New session: the next frame must be a keyframe. */
    fun reset() { lastKeyframeAt = Long.MIN_VALUE; lastW = -1; lastH = -1 }
}

/** 3+ taps within 700 ms and 48 dp of each other; fires once per burst. */
internal class RageClickDetector(
    private val windowMs: Long = 700,
    private val radiusDp: Float = 48f,
    private val minTaps: Int = 3,
) {
    private data class Tap(val t: Long, val x: Float, val y: Float)
    private val taps = ArrayDeque<Tap>()
    private var firedFor: Tap? = null

    /** Returns true when this tap completes a rage click. */
    fun onTap(t: Long, xDp: Float, yDp: Float): Boolean {
        while (taps.isNotEmpty() && t - taps.first().t > windowMs) taps.removeFirst()
        val near = taps.filter { hypot(it.x - xDp, it.y - yDp) <= radiusDp }
        // A burst that already fired keeps going without firing again.
        val burstStart = near.firstOrNull()
        val tap = Tap(t, xDp, yDp)
        taps.addLast(tap)
        if (near.size + 1 >= minTaps) {
            val f = firedFor
            if (f != null && near.contains(f)) { firedFor = tap; return false }
            firedFor = tap
            return burstStart != null
        }
        return false
    }
}

/** Drops calls that come sooner than [intervalMs] after the last accepted one. */
internal class Throttle(private val intervalMs: Long) {
    private var last = Long.MIN_VALUE
    fun allow(now: Long): Boolean {
        if (last != Long.MIN_VALUE && now - last < intervalMs) return false
        last = now
        return true
    }
    fun reset() { last = Long.MIN_VALUE }
}
