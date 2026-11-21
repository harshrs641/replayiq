package com.replayiq.android

import android.app.Application
import android.content.Context
import android.view.View
import com.replayiq.android.internal.Log
import com.replayiq.android.internal.Recorder

/**
 * ReplayIQ session replay for Android.
 *
 * ```kotlin
 * class App : Application() {
 *     override fun onCreate() {
 *         super.onCreate()
 *         ReplayIQ.start(this, "<ingest key>", "https://ingest.example.com")
 *     }
 * }
 * ```
 *
 * Every method is static for Java (`ReplayIQ.start(...)`), safe to call from any thread and
 * never throws: SDK failures are caught and only logged when [ReplayIQOptions.debug] is on.
 */
object ReplayIQ {
    /** `replayiq-android/<semver>`, sent as `sdk`. */
    const val SDK_NAME = "replayiq-android"

    @JvmStatic
    val sdkVersion: String
        get() = BuildConfig.SDK_VERSION

    /**
     * Start recording. Call once, from `Application.onCreate()` (calls after the first are ignored).
     *
     * @param context any context; the application context is kept.
     * @param key the project's ingest key (for now: the project id).
     * @param endpoint ingest base URL, e.g. `https://ingest.replayiq.example` (the emulator reaches
     *   a local stack at `http://10.0.2.2:8080`).
     */
    @JvmStatic
    @JvmOverloads
    fun start(context: Context, key: String, endpoint: String, options: ReplayIQOptions = ReplayIQOptions()) = safe {
        val app = context.applicationContext as? Application
            ?: error("ReplayIQ.start needs an Application context")
        Recorder.start(app, key, endpoint, options, context as? android.app.Activity)
    }

    /** Set the user for this session (and the next). [traits] are stored as session metadata. */
    @JvmStatic
    @JvmOverloads
    fun identify(userId: String, traits: Map<String, String>? = null) = safe { Recorder.current?.identify(userId, traits) }

    /** Record one of the app's own named events (`custom_events`). Values should be strings, numbers or booleans. */
    @JvmStatic
    @JvmOverloads
    fun track(name: String, properties: Map<String, Any?>? = null) = safe { Recorder.current?.track(name, properties) }

    /** Name the current screen (`navigate`). Use for Compose / single-activity apps; activities and fragments are automatic. */
    @JvmStatic
    fun screen(name: String) = safe { Recorder.current?.screen(name) }

    /** Add a `console` line. [level] is `log`, `warn` or `error`. */
    @JvmStatic
    @JvmOverloads
    fun log(message: String, level: String = "log") = safe { Recorder.current?.log(message, level, null) }

    /** Record a handled error as `console` (`error`) with its stack. */
    @JvmStatic
    fun logError(throwable: Throwable) = safe { Recorder.current?.logError(throwable) }

    /**
     * Record one HTTP request (`network`). The OkHttp interceptor ([ReplayIQOkHttpInterceptor]) calls this;
     * use it directly for other clients. [status] 0 plus [error] when no response arrived.
     */
    @JvmStatic
    @JvmOverloads
    fun recordNetwork(method: String, url: String, status: Int, durationMs: Long, error: String? = null) =
        safe { Recorder.current?.network(method, url, status, durationMs, error) }

    /**
     * Report that the app was opened from a notification (`push_open`). Firebase notification opens
     * and intents carrying the `replayiq_push_campaign` extra are detected automatically.
     */
    @JvmStatic
    fun pushOpened(campaign: String) = safe { Recorder.current?.signals?.pushOpen(campaign) }

    /** Report the answer to a permission prompt (`permission`); [result] is `granted`, `denied` or `limited`. */
    @JvmStatic
    fun permissionResult(name: String, result: String) = safe { Recorder.current?.signals?.permission(name, result) }

    /** Paint [view] (and everything inside it) over in recordings. Same as `android:tag="replayiq-mask"`. */
    /** Decides whether a view is masked; see [maskPredicate]. */
    fun interface MaskPredicate {
        fun shouldMask(view: View): Boolean
    }

    /**
     * Masks any view for which this returns true, in addition to [mask] and the
     * default rules. Called on the main thread for many views per capture: keep
     * it cheap. Wrappers use it to mask by their own markers (e.g. React
     * Native's `nativeID`).
     */
    @JvmStatic
    @Volatile
    var maskPredicate: MaskPredicate? = null

    /**
     * Records an error from the app's own runtime (e.g. JavaScript in React
     * Native) as `js_error`, with its stack and source location.
     */
    @JvmStatic
    @JvmOverloads
    fun recordError(message: String, stack: String? = null, filename: String? = null, line: Int = 0, column: Int = 0) =
        safe { Recorder.current?.recordError(message, stack, filename, line, column) }

    @JvmStatic
    fun mask(view: View) = safe { view.setTag(R.id.replayiq_mask, true) }

    /** Record [view] even though a default rule (e.g. maskAllInputs) would mask it. */
    @JvmStatic
    fun unmask(view: View) = safe { view.setTag(R.id.replayiq_mask, false) }

    /** Stop recording and sending, and forget the queued data, until [optIn]. Persisted across launches. */
    @JvmStatic
    fun optOut() = safe { Recorder.current?.optOut() }

    /** Allow recording again after [optOut]; starts a new session. */
    @JvmStatic
    fun optIn() = safe { Recorder.current?.optIn() }

    @JvmStatic
    val isOptedOut: Boolean
        get() = Recorder.current?.isOptedOut() ?: false

    /** End the session (logout / reset): queued data is sent and the next foreground starts a new session. */
    @JvmStatic
    fun stop() = safe { Recorder.current?.endSession(restart = false) }

    /** End the current session and start a new one immediately (e.g. after logout). */
    @JvmStatic
    fun reset() = safe { Recorder.current?.endSession(restart = true) }

    /** Change the sample rate for sessions started from now on. */
    @JvmStatic
    fun setSampleRate(rate: Double) = safe { Recorder.current?.setSampleRate(rate) }

    /** The current session id, or null when not recording (not started, opted out or not sampled). */
    @JvmStatic
    val sessionId: String?
        get() = Recorder.current?.recordingSessionId()

    /**
     * Diagnostics: what recording has cost since the last reset (bytes sent, events per minute,
     * walk / diff times, worst frame). Counters only fill with [ReplayIQOptions.debug] on.
     */
    @JvmStatic
    @JvmOverloads
    fun debugStats(reset: Boolean = false): String {
        val mode = Recorder.current?.let { it.mode } ?: "off"
        return com.replayiq.android.internal.Stats.summary(mode).also { if (reset) com.replayiq.android.internal.Stats.reset() }
    }

    /** Send buffered events now. */
    @JvmStatic
    fun flush() = safe { Recorder.current?.flushAsync() }

    private inline fun safe(block: () -> Unit) {
        try {
            block()
        } catch (t: Throwable) {
            Log.w("ReplayIQ call failed", t)
        }
    }
}
