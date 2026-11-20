package com.replayiq.android.internal

/**
 * Records uncaught exceptions as `js_error`: the event is written to the disk queue synchronously
 * (sent on the next launch), then the previous handler runs (the system crash dialog, Crashlytics...).
 */
internal class CrashHandler(
    private val previous: Thread.UncaughtExceptionHandler?,
    private val onCrash: (Thread, Throwable) -> Unit,
) : Thread.UncaughtExceptionHandler {
    @Volatile private var handling = false

    override fun uncaughtException(t: Thread, e: Throwable) {
        if (!handling) {
            handling = true
            try { onCrash(t, e) } catch (_: Throwable) {}
        }
        previous?.uncaughtException(t, e)
    }

    companion object {
        fun install(onCrash: (Thread, Throwable) -> Unit): CrashHandler {
            val h = CrashHandler(Thread.getDefaultUncaughtExceptionHandler(), onCrash)
            Thread.setDefaultUncaughtExceptionHandler(h)
            return h
        }
    }
}
