package com.replayiq.android.internal

/** Logcat logging, only when ReplayIQOptions.debug is on. Never throws. */
internal object Log {
    @Volatile var enabled = false
    private const val TAG = "ReplayIQ"

    fun d(msg: String) {
        if (enabled) try { android.util.Log.d(TAG, msg) } catch (_: Throwable) {}
    }

    fun w(msg: String, t: Throwable? = null) {
        if (enabled) try { android.util.Log.w(TAG, msg, t) } catch (_: Throwable) {}
    }
}
