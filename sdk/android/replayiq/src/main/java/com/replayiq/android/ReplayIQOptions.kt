package com.replayiq.android

import android.graphics.Color

/**
 * Recording options. Build from Java with [Builder]:
 *
 * ```java
 * ReplayIQOptions options = new ReplayIQOptions.Builder()
 *     .sampleRate(0.5)
 *     .debug(BuildConfig.DEBUG)
 *     .build();
 * ```
 *
 * Every field has a safe default, so `ReplayIQOptions()` / `new ReplayIQOptions.Builder().build()` is fine.
 */
class ReplayIQOptions private constructor(b: Builder) {
    /** Fraction of sessions recorded, 0–1. Decided once per session, before anything is recorded. */
    val sampleRate: Double = b.sampleRate.coerceIn(0.0, 1.0)

    /** Paint over every EditText (and Compose text field). Default true. Opt single fields out with [ReplayIQ.unmask]. */
    val maskAllInputs: Boolean = b.maskAllInputs

    /** Paint over every TextView (and Compose Text). Default false. */
    val maskAllText: Boolean = b.maskAllText

    /** Paint over every ImageView (and Compose Image). Default false. */
    val maskAllImages: Boolean = b.maskAllImages

    /** Paint over WebViews (their content is not inspected). Default false. */
    val maskWebViews: Boolean = b.maskWebViews

    /** Record screenshots. When false only touches and app events are sent. Default true. */
    val captureScreens: Boolean = b.captureScreens

    /** Install the Window.Callback wrapper that records touches, clicks and rage clicks. Default true. */
    val captureTouches: Boolean = b.captureTouches

    /** Record uncaught exceptions as `js_error` (sent on the next launch). Default true. */
    val captureCrashes: Boolean = b.captureCrashes

    /** Keep the query string of recorded network URLs. Default false (it often carries tokens). */
    val captureNetworkQuery: Boolean = b.captureNetworkQuery

    /** Screenshot resolution in pixels per dp (1.0 = one pixel per dp). Clamped to 0.5–2. */
    val imageScale: Float = b.imageScale.coerceIn(0.5f, 2f)

    /** JPEG quality, 1–100. Default 60. */
    val jpegQuality: Int = b.jpegQuality.coerceIn(1, 100)

    /** Max screenshots per second, ≤ 2 (the protocol limit). */
    val maxFps: Double = b.maxFps.coerceIn(0.1, 2.0)

    /** Colour painted over masked areas. */
    val maskColor: Int = b.maskColor

    /** Batch flush interval in ms. Default 5000. */
    val flushIntervalMs: Long = b.flushIntervalMs.coerceAtLeast(1000)

    /** A session ends after this long in the background. Default 30 min. */
    val sessionTimeoutMs: Long = b.sessionTimeoutMs.coerceAtLeast(10_000)

    /** Sent as `project_id`; when null the server takes the project from the key. */
    val projectId: String? = b.projectId

    /** Log SDK activity to Logcat (tag "ReplayIQ"). Turn on for debug builds only. */
    val debug: Boolean = b.debug

    /** `platform` reported to the server: `android`, or the wrapping SDK's (e.g. `react-native`). */
    val platform: String = b.platform

    /** `sdk` reported to the server, `<name>/<semver>`; null = `replayiq-android/<version>`. */
    val sdk: String? = b.sdk

    /**
     * How screens are recorded. [RecordingMode.AUTO] (default): Native DOM (the UI as a tree of
     * nodes, ~30x smaller than screenshots), switching to screenshots for a screen that is mostly
     * made of views the DOM can't describe (maps, video, games, custom drawing).
     */
    val recordingMode: RecordingMode = b.recordingMode

    enum class RecordingMode {
        /** Native DOM, with screenshots for screens that are mostly islands. */
        AUTO,
        /** Always Native DOM (recording API v1.1). */
        NATIVE_DOM,
        /** Always screenshots (recording API v1). */
        SCREENSHOT,
    }

    /** Defaults for everything. */
    constructor() : this(Builder())

    fun toBuilder(): Builder = Builder().also {
        it.sampleRate = sampleRate; it.maskAllInputs = maskAllInputs; it.maskAllText = maskAllText
        it.maskAllImages = maskAllImages; it.maskWebViews = maskWebViews; it.captureScreens = captureScreens
        it.captureTouches = captureTouches; it.captureCrashes = captureCrashes
        it.captureNetworkQuery = captureNetworkQuery; it.imageScale = imageScale; it.jpegQuality = jpegQuality
        it.maxFps = maxFps; it.maskColor = maskColor; it.flushIntervalMs = flushIntervalMs
        it.sessionTimeoutMs = sessionTimeoutMs; it.projectId = projectId; it.debug = debug
        it.platform = platform; it.sdk = sdk; it.recordingMode = recordingMode
    }

    class Builder {
        internal var sampleRate = 1.0
        internal var maskAllInputs = true
        internal var maskAllText = false
        internal var maskAllImages = false
        internal var maskWebViews = false
        internal var captureScreens = true
        internal var captureTouches = true
        internal var captureCrashes = true
        internal var captureNetworkQuery = false
        internal var imageScale = 1.0f
        internal var jpegQuality = 60
        internal var maxFps = 2.0
        internal var maskColor = Color.rgb(0x9A, 0x9F, 0xA8)
        internal var flushIntervalMs = 5_000L
        internal var sessionTimeoutMs = 30 * 60_000L
        internal var projectId: String? = null
        internal var debug = false
        internal var platform = "android"
        internal var sdk: String? = null
        internal var recordingMode = RecordingMode.AUTO

        fun sampleRate(value: Double) = apply { sampleRate = value }
        fun maskAllInputs(value: Boolean) = apply { maskAllInputs = value }
        fun maskAllText(value: Boolean) = apply { maskAllText = value }
        fun maskAllImages(value: Boolean) = apply { maskAllImages = value }
        fun maskWebViews(value: Boolean) = apply { maskWebViews = value }
        fun captureScreens(value: Boolean) = apply { captureScreens = value }
        fun captureTouches(value: Boolean) = apply { captureTouches = value }
        fun captureCrashes(value: Boolean) = apply { captureCrashes = value }
        fun captureNetworkQuery(value: Boolean) = apply { captureNetworkQuery = value }
        fun imageScale(value: Float) = apply { imageScale = value }
        fun jpegQuality(value: Int) = apply { jpegQuality = value }
        fun maxFps(value: Double) = apply { maxFps = value }
        fun maskColor(value: Int) = apply { maskColor = value }
        fun flushIntervalMs(value: Long) = apply { flushIntervalMs = value }
        fun sessionTimeoutMs(value: Long) = apply { sessionTimeoutMs = value }
        fun projectId(value: String?) = apply { projectId = value }
        fun debug(value: Boolean) = apply { debug = value }
        fun recordingMode(value: RecordingMode) = apply { recordingMode = value }

        /** For SDKs built on this one (React Native): `wrapper("react-native", "replayiq-react-native/1.0.0")`. */
        fun wrapper(platform: String, sdk: String) = apply { this.platform = platform; this.sdk = sdk }
        fun build() = ReplayIQOptions(this)
    }
}
