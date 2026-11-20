package com.replayiq.android.internal

import android.app.Activity
import android.app.Application
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.Process
import com.replayiq.android.ReplayIQ
import com.replayiq.android.ReplayIQOptions
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.lang.ref.WeakReference
import java.util.Locale
import java.util.UUID
import kotlin.math.roundToInt

/**
 * The SDK engine: session lifecycle, sampling, the event buffer, batching to the disk queue, and
 * wiring of the capture components to the app's activities.
 *
 * Threads: activity callbacks, capture planning, touches and inputs run on the main thread;
 * flushing, encoding and file writes on the worker thread; HTTP on the upload thread.
 */
internal class Recorder internal constructor(
    private val app: Application,
    private val key: String,
    endpoint: String,
    private val options: ReplayIQOptions,
    sender: HttpSender = UrlConnectionSender,
    private val clock: () -> Long = System::currentTimeMillis,
    private val random: () -> Double = Math::random,
    queueDir: File = File(app.noBackupFilesDir, "replayiq/queue"),
) {
    private val endpoint = endpoint.trimEnd('/')
    private val store = SessionStore(app)
    private val queue = DiskQueue(queueDir)
    private val main = Handler(Looper.getMainLooper())
    private val workerThread = HandlerThread("ReplayIQ-worker", Process.THREAD_PRIORITY_BACKGROUND).apply { start() }
    internal val worker = Handler(workerThread.looper)
    private val assets = AssetStore(File(queueDir.parentFile ?: app.noBackupFilesDir, "assets"), queue)
    private val uploader = Uploader(queue, this.endpoint, key, sender, onStop = { disableForRun() }, assets = assets)
    private val inspector = ViewInspector(options)
    private val capturer = ScreenCapturer(options, inspector, worker, ::addEvent, clock)
    private val dom = DomRecorder(options, inspector, worker, assets, ::addEvent, clock, onIslandHeavy = { onIslandHeavyScreen() })
    internal val signals = Signals(app, worker, ::addEvent, clock, { currentScreen }, options.captureNetworkQuery)
    private val touches = TouchTracker(inspector, ::addEvent, clock)
    private val inputs = InputWatcher(inspector, ::addEvent, clock)

    // Buffer (any thread).
    private val bufferLock = Any()
    private var buffer = ArrayList<JSONObject>()
    private var bufferBytes = 0L
    private var custom = ArrayList<JSONObject>()

    // Session (guarded by sessionLock; changed on the worker thread, read by the crash handler).
    private val sessionLock = Any()
    @Volatile private var session: SessionState? = null

    @Volatile private var optedOut = store.optedOut
    @Volatile private var disabled = false   // ingest key rejected: off for this run
    @Volatile private var stopped = false    // ReplayIQ.stop()
    @Volatile private var sampleRate = options.sampleRate
    @Volatile private var userId: String? = store.userId
    @Volatile private var traits: Map<String, String> = store.traits

    // Main thread.
    private var startedActivities = 0
    private var foreground = false
    private var backgroundedAt = 0L
    private var currentActivity: WeakReference<Activity>? = null
    private var resumedActivity: Activity? = null
    private var skipNextActivityName = false
    @Volatile private var currentScreen: String? = null
    private var lastNavigated: String? = null
    /** AUTO mode: the screen being recorded with screenshots because it's mostly islands. */
    private var screenshotScreen: String? = null
    private var lastStatsLog = 0L
    /** Cost counters: with `debug(true)`, or in any build after `adb shell setprop log.tag.ReplayIQStats DEBUG` (then restart the app). */
    private val statsOn = options.debug || try { android.util.Log.isLoggable(STATS_TAG, android.util.Log.DEBUG) } catch (_: Throwable) { false }

    private val packageName: String = app.packageName
    private val sdkId = options.sdk ?: "${ReplayIQ.SDK_NAME}/${ReplayIQ.sdkVersion}"

    private val flushTick = object : Runnable {
        override fun run() {
            flush()
            if (statsOn && clock() - lastStatsLog >= STATS_LOG_MS) {
                lastStatsLog = clock()
                val line = Stats.summary(options.recordingMode.name)
                if (options.debug) Log.d(line) else android.util.Log.d(STATS_TAG, line)
            }
            worker.postDelayed(this, options.flushIntervalMs)
        }
    }
    private val backgroundTimeout = Runnable { endCurrent(endedAt = backgroundedAtWorker) }
    @Volatile private var backgroundedAtWorker = 0L

    internal fun init(startActivity: Activity?) {
        Log.enabled = options.debug
        if (options.captureCrashes) CrashHandler.install(::onCrash)
        app.registerActivityLifecycleCallbacks(callbacks)
        signals.start(lateStart = startActivity != null)
        worker.post {
            restoreOrStartSession()
            uploader.kick()
            worker.postDelayed(flushTick, options.flushIntervalMs)
            main.post { updateCapture() }
        }
        // Started late (after consent, or from a React Native module): adopt the visible activity.
        if (startActivity != null) runOnMain {
            callbacks.onActivityStarted(startActivity)
            callbacks.onActivityResumed(startActivity)
        }
        Log.d("started: endpoint=$endpoint sdk=${ReplayIQ.SDK_NAME}/${ReplayIQ.sdkVersion}")
    }

    // ---------------------------------------------------------------- session lifecycle (worker)

    private fun restoreOrStartSession() {
        val now = clock()
        val stored = store.load()
        if (stored != null && now - stored.lastActive <= options.sessionTimeoutMs && !optedOut) {
            stored.lastActive = now
            synchronized(sessionLock) { session = stored }
            store.save(stored)
            main.post { capturer.newSession(); dom.newSession() } // a new process: the first frame is a keyframe
            Log.d("resumed session ${stored.id} (sampled=${stored.sampled})")
            return
        }
        if (stored != null) {
            synchronized(sessionLock) { session = stored }
            endCurrent(endedAt = stored.lastActive)
        }
        if (!optedOut && !stopped) newSession()
    }

    private fun newSession() {
        val now = clock()
        val s = SessionState(UUID.randomUUID().toString(), now, sampled = random() < sampleRate, lastActive = now)
        synchronized(sessionLock) { session = s }
        store.save(s)
        main.post { capturer.newSession(); dom.newSession(); updateCapture() }
        Log.d("new session ${s.id} (sampled=${s.sampled})")
    }

    /** Sends what's buffered and the session end. Worker thread. */
    private fun endCurrent(endedAt: Long) {
        val s = session ?: return
        flush()
        synchronized(sessionLock) {
            if (s.sampled && s.created && !optedOut && !disabled) {
                val end = clampEnd(s, endedAt)
                val body = JSONObject().put("ended_at", Json.iso8601(end)).put("duration_ms", (end - s.startedAt).coerceAtLeast(0))
                queue.add("/api/v1/sessions/${s.id}/end", body.toString())
            }
            session = null
            store.save(null)
        }
        uploader.kick()
        main.post { updateCapture() }
        Log.d("ended session ${s.id}")
    }

    private fun clampEnd(s: SessionState, endedAt: Long) = endedAt.coerceAtLeast(s.startedAt).takeIf { it > 0 } ?: clock()

    fun endSession(restart: Boolean) {
        if (!restart) stopped = true
        worker.post {
            endCurrent(clock())
            if (restart && !optedOut) newSession()
        }
    }

    /** ReplayIQ.start() after stop(): record again. */
    fun restart() {
        if (!stopped) return
        stopped = false
        worker.post { if (session == null && !optedOut) newSession() }
    }

    fun isRecording(): Boolean = !disabled && !optedOut && !stopped && session?.sampled == true

    fun recordingSessionId(): String? = if (isRecording()) session?.id else null

    fun isOptedOut() = optedOut

    /** The mode screens are recorded in right now (AUTO may be using screenshots for this screen). */
    val mode: String get() = options.recordingMode.name + if (useScreenshots()) "/screenshot" else "/native_dom"

    fun optOut() {
        optedOut = true
        store.optedOut = true
        synchronized(bufferLock) { buffer = ArrayList(); custom = ArrayList(); bufferBytes = 0 }
        worker.post {
            synchronized(sessionLock) { session = null; store.save(null) }
            queue.clear()
            assets.clearQueued()
        }
        runOnMain { updateCapture() }
    }

    fun optIn() {
        if (!optedOut) return
        optedOut = false
        store.optedOut = false
        worker.post { if (session == null && !stopped) newSession() }
    }

    fun setSampleRate(rate: Double) { sampleRate = rate.coerceIn(0.0, 1.0) }

    private fun disableForRun() {
        disabled = true
        synchronized(bufferLock) { buffer = ArrayList(); custom = ArrayList(); bufferBytes = 0 }
        main.post { updateCapture() }
    }

    // ---------------------------------------------------------------- events

    /** Any thread. */
    fun addEvent(ev: JSONObject) {
        if (!isRecording()) return
        val size = eventSize(ev)
        if (statsOn) Stats.event(ev)
        val full: Boolean
        synchronized(bufferLock) {
            buffer.add(ev)
            bufferBytes += size
            full = buffer.size >= MAX_BATCH_EVENTS || bufferBytes >= MAX_BATCH_BYTES
        }
        if (full) worker.post { flush() }
    }

    /** Rough serialised size: screenshots by their image, Native DOM events by their JSON. */
    private fun eventSize(e: JSONObject): Long {
        val sub = e.optString("subtype")
        return if (sub == "ui_snapshot" || sub == "ui_mutation") e.toString().length.toLong() else e.optString("image").length + 256L
    }

    fun identify(id: String, t: Map<String, String>?) {
        userId = id
        store.userId = id
        if (t != null) { traits = traits + t; store.traits = traits }
        if (session?.created == true) Log.d("identify after the session was created: user_id applies from the next session")
    }

    fun track(name: String, properties: Map<String, Any?>?) {
        if (!isRecording()) return
        val e = JSONObject().put("name", name).put("timestamp", clock())
        if (properties != null) e.put("properties", Json.value(properties))
        synchronized(bufferLock) { custom.add(e) }
    }

    fun screen(name: String) = runOnMain {
        // Named while an activity is being created: that name replaces the activity's own.
        if (resumedActivity == null) skipNextActivityName = true
        else if (name != lastNavigated) signals.onScreen(resumedActivity, name)
        navigate(name)
    }

    private fun navigate(name: String) {
        currentScreen = name
        if (name == lastNavigated) return
        lastNavigated = name
        addEvent(Events.navigate(clock(), "app://$packageName/$name", "Screen: $name"))
        dom.requestSnapshot()
        if (screenshotScreen != null && screenshotScreen != name) {
            screenshotScreen = null // AUTO: back to Native DOM on the next screen
            updateCapture()
        }
    }

    /** AUTO mode: this screen is mostly islands (maps, video, games): record it with screenshots. */
    private fun onIslandHeavyScreen() {
        if (options.recordingMode != ReplayIQOptions.RecordingMode.AUTO) return
        val name = currentScreen ?: return
        if (screenshotScreen == name) return
        screenshotScreen = name
        Log.d("screen $name is mostly islands: recording it with screenshots")
        updateCapture()
    }

    private fun useScreenshots(): Boolean = when (options.recordingMode) {
        ReplayIQOptions.RecordingMode.SCREENSHOT -> true
        ReplayIQOptions.RecordingMode.NATIVE_DOM -> false
        ReplayIQOptions.RecordingMode.AUTO -> screenshotScreen != null && screenshotScreen == currentScreen
    }

    fun log(message: String, level: String, stack: String?) = addEvent(Events.console(clock(), level, message, stack))

    fun recordError(message: String, stack: String?, filename: String?, line: Int, column: Int) =
        addEvent(Events.runtimeError(clock(), message, stack, filename, line, column))

    fun logError(t: Throwable) =
        log("${t.javaClass.name}: ${t.message ?: ""}", "error", android.util.Log.getStackTraceString(t))

    fun network(method: String, url: String, status: Int, durationMs: Long, error: String?) {
        if (url.startsWith("$endpoint/api/v1/sessions") || url.startsWith("$endpoint/api/v1/events")) return // our own uploads
        addEvent(Events.network(clock(), method, Events.sanitizeUrl(url, options.captureNetworkQuery), status, durationMs, error))
    }

    fun flushAsync() { worker.post { flush() } }

    /** Buffer → batches in the disk queue → upload. Worker thread. */
    internal fun flush() {
        val events: ArrayList<JSONObject>
        val customEvents: ArrayList<JSONObject>
        synchronized(bufferLock) {
            events = buffer; customEvents = custom
            buffer = ArrayList(); custom = ArrayList(); bufferBytes = 0
        }
        val s = session ?: return
        if (!isRecording()) return
        if (events.isEmpty() && customEvents.isEmpty()) return
        try {
            synchronized(sessionLock) { writeBatches(s, events, customEvents, clock()) }
            store.save(s)
            uploader.kick()
        } catch (t: Throwable) {
            Log.w("flush failed", t)
        }
    }

    /** Caller holds sessionLock. */
    private fun writeBatches(s: SessionState, events: List<JSONObject>, customEvents: List<JSONObject>, now: Long) {
        if (!s.created) {
            queue.add("/api/v1/sessions", sessionBody(s).toString())
            s.created = true
        }
        val sorted = events.sortedBy { it.optLong("timestamp") }
        // Chunk so each request stays well under the 5 MB body limit.
        val chunks = ArrayList<List<JSONObject>>()
        var cur = ArrayList<JSONObject>(); var bytes = 0L
        for (e in sorted) {
            val sz = eventSize(e)
            if (cur.isNotEmpty() && (bytes + sz > MAX_BATCH_BYTES || cur.size >= MAX_REQUEST_EVENTS)) {
                chunks.add(cur); cur = ArrayList(); bytes = 0
            }
            cur.add(e); bytes += sz
        }
        if (cur.isNotEmpty() || customEvents.isNotEmpty()) chunks.add(cur)
        chunks.forEachIndexed { i, chunk ->
            s.seq += 1
            val body = JSONObject()
                .put("session_id", s.id)
                .put("batch_id", String.format(Locale.US, "%s-%06d", s.id, s.seq))
                .put("platform", options.platform)
                .put("sdk", sdkId)
                .put("device_masked", true)
                .put("flushed_at", Json.iso8601(now))
                .put("events", JSONArray(chunk))
            options.projectId?.let { body.put("project_id", it) }
            if (i == 0 && customEvents.isNotEmpty()) body.put("custom_events", JSONArray(customEvents))
            queue.add(DiskQueue.EVENTS_PATH, body.toString())
        }
        s.lastActive = now
    }

    private fun sessionBody(s: SessionState): JSONObject {
        val dm = app.resources.displayMetrics
        val meta = JSONObject()
            .put("platform", options.platform)
            .put("os", "android")
            .put("os_version", Build.VERSION.RELEASE ?: "")
            .put("api_level", Build.VERSION.SDK_INT.toString())
            .put("app_version", appVersion())
            .put("device", listOfNotNull(Build.MANUFACTURER, Build.MODEL).joinToString(" "))
            .put("bundle_id", packageName)
            .put("locale", Locale.getDefault().toLanguageTag())
            .put("text_scale", app.resources.configuration.fontScale.toDouble())
            .put("screen_density", dm.density.toDouble())
            .put("recording_mode", options.recordingMode.name.lowercase(Locale.US))
        traits.forEach { (k, v) -> if (!meta.has(k)) meta.put(k, v) }
        return JSONObject()
            .put("session_id", s.id)
            .apply { options.projectId?.let { put("project_id", it) } }
            .put("user_id", userId ?: "")
            .put("url", "app://$packageName/${currentScreen ?: "launch"}")
            .put("user_agent", "$sdkId (Android ${Build.VERSION.RELEASE}; API ${Build.VERSION.SDK_INT}; ${Build.MODEL})")
            .put("screen_width", (dm.widthPixels / dm.density).roundToInt())
            .put("screen_height", (dm.heightPixels / dm.density).roundToInt())
            .put("sdk_version", sdkId)
            .put("started_at", Json.iso8601(s.startedAt))
            .put("metadata", meta)
    }

    private fun appVersion(): String = try {
        val pi = app.packageManager.getPackageInfo(packageName, 0)
        @Suppress("DEPRECATION")
        val code = if (Build.VERSION.SDK_INT >= 28) pi.longVersionCode else pi.versionCode.toLong()
        "${pi.versionName ?: "?"} ($code)"
    } catch (_: PackageManager.NameNotFoundException) { "" }

    // ---------------------------------------------------------------- crashes

    /** On the crashing thread: write everything synchronously, the process is about to die. */
    private fun onCrash(thread: Thread, e: Throwable) {
        if (!isRecording()) return
        val s = session ?: return
        val now = clock()
        val events: ArrayList<JSONObject>
        val customEvents: ArrayList<JSONObject>
        synchronized(bufferLock) {
            events = buffer; customEvents = custom
            buffer = ArrayList(); custom = ArrayList(); bufferBytes = 0
        }
        events.add(Events.jsError(now, e).put("thread", thread.name))
        synchronized(sessionLock) { writeBatches(s, events, customEvents, now) }
        store.save(s, sync = true)
        Log.d("crash recorded for session ${s.id}; sent on next launch")
    }

    // ---------------------------------------------------------------- activities (main thread)

    private fun updateCapture() {
        val on = foreground && isRecording()
        touches.enabled = on
        inputs.enabled = on
        if (!on || !options.captureScreens) { capturer.stop(); dom.stop(); return }
        if (useScreenshots()) {
            if (dom.running) { dom.stop(); capturer.newSession() } // switching modes: start with a keyframe
            capturer.start()
        } else {
            capturer.stop()
            dom.start()
        }
    }

    private fun onForeground() {
        foreground = true
        signals.onForeground()
        val bgAt = backgroundedAt
        worker.removeCallbacks(backgroundTimeout)
        worker.post {
            val s = session
            val now = clock()
            if (s != null && bgAt > 0 && now - bgAt > options.sessionTimeoutMs) {
                endCurrent(bgAt)
            }
            if (session == null && !optedOut && !stopped) newSession() else session?.let { it.lastActive = now }
            uploader.kickNow()
            main.post { updateCapture() }
        }
    }

    private fun onBackground() {
        foreground = false
        signals.onBackground()
        backgroundedAt = clock()
        backgroundedAtWorker = backgroundedAt
        updateCapture()
        worker.post {
            flush()
            session?.let { synchronized(sessionLock) { it.lastActive = backgroundedAtWorker; store.save(it) } }
            uploader.kickNow()
        }
        worker.postDelayed(backgroundTimeout, options.sessionTimeoutMs)
    }

    private val callbacks = object : Application.ActivityLifecycleCallbacks {
        override fun onActivityPreCreated(activity: Activity, savedInstanceState: Bundle?) {
            signals.onActivityPreCreated(activity)
        }

        override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {
            FragmentTracker.register(activity) { name ->
                if (name != lastNavigated) signals.onScreen(activity, name)
                navigate(name)
            }
            try { signals.onActivityCreated(activity, savedInstanceState != null, startedActivities == 0) } catch (t: Throwable) { Log.w("signals failed", t) }
        }

        override fun onActivityStarted(activity: Activity) {
            startedActivities++
            if (startedActivities == 1) onForeground()
        }

        override fun onActivityResumed(activity: Activity) {
            try {
                currentActivity = WeakReference(activity)
                activity.window?.let { w ->
                    if (options.captureTouches) touches.install(w)
                    w.peekDecorView()?.let { inputs.observe(it) }
                }
                resumedActivity = activity
                capturer.setActivity(activity)
                dom.setActivity(activity)
                dom.requestSnapshot() // resume: a fresh snapshot
                signals.onActivityResumed(activity)
                if (skipNextActivityName) skipNextActivityName = false else navigate(activity.javaClass.simpleName)
                updateCapture()
            } catch (t: Throwable) {
                Log.w("activity tracking failed", t)
            }
        }

        override fun onActivityPaused(activity: Activity) {
            if (resumedActivity === activity) resumedActivity = null
        }

        override fun onActivityStopped(activity: Activity) {
            startedActivities = (startedActivities - 1).coerceAtLeast(0)
            if (startedActivities == 0 && !activity.isChangingConfigurations) onBackground()
        }

        override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) {}

        override fun onActivityDestroyed(activity: Activity) {
            if (currentActivity?.get() === activity) {
                currentActivity = null
                capturer.setActivity(null)
                dom.setActivity(null)
            }
            signals.onActivityDestroyed(activity)
        }
    }

    private fun runOnMain(block: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) block() else main.post(block)
    }

    companion object {
        const val MAX_BATCH_EVENTS = 50
        const val MAX_REQUEST_EVENTS = 100
        const val MAX_BATCH_BYTES = 3L * 1024 * 1024
        const val STATS_LOG_MS = 15_000L
        const val STATS_TAG = "ReplayIQStats"

        @Volatile var current: Recorder? = null
            private set

        @Synchronized
        fun start(app: Application, key: String, endpoint: String, options: ReplayIQOptions, activity: Activity?) {
            val existing = current
            if (existing != null) {
                existing.restart()
                return
            }
            require(key.isNotBlank()) { "ReplayIQ: empty ingest key" }
            require(endpoint.startsWith("http://") || endpoint.startsWith("https://")) { "ReplayIQ: endpoint must be an http(s) URL" }
            current = Recorder(app, key, endpoint, options).also { it.init(activity) }
        }

        /** Tests only. */
        internal fun setCurrentForTest(r: Recorder?) { current = r }
    }
}
