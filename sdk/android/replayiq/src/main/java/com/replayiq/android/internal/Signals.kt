package com.replayiq.android.internal

import android.Manifest
import android.app.Activity
import android.app.Application
import android.content.BroadcastReceiver
import android.content.ComponentCallbacks2
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.content.pm.PermissionInfo
import android.content.res.Configuration
import android.graphics.Rect
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Build
import android.os.Debug
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.Process
import android.os.SystemClock
import android.view.FrameMetrics
import android.view.View
import android.view.ViewTreeObserver
import android.view.Window
import android.view.WindowInsets
import org.json.JSONObject
import java.util.WeakHashMap

/**
 * Mobile signals (recording API v1.1 §2) Android can supply: lifecycle, app_start, screen_load,
 * jank (FrameMetrics), hang (main-thread watchdog), memory, keyboard, orientation, connectivity,
 * deeplink, push_open, permission, thermal / power. Lifecycle hooks run on the main thread;
 * events go through [emit] (dropped unless the session is being recorded).
 */
internal class Signals(
    private val app: Application,
    private val worker: Handler,
    private val emit: (JSONObject) -> Unit,
    private val clock: () -> Long,
    private val screen: () -> String?,
    private val keepQuery: Boolean,
) {
    private val main = Handler(Looper.getMainLooper())
    private var coldStartPending = true
    private var firstForeground = true
    private val createdAt = WeakHashMap<Activity, Long>()
    private val frameListeners = WeakHashMap<Window, Window.OnFrameMetricsAvailableListener>()
    private val keyboardRoots = WeakHashMap<View, Boolean>()

    fun start(lateStart: Boolean) {
        // Started after the first activity was shown: its launch time can't be measured.
        if (lateStart) coldStartPending = false
        app.registerComponentCallbacks(componentCallbacks)
        lastOrientation = app.resources.configuration.orientation
        worker.post {
            try { loadPermissions() } catch (t: Throwable) { Log.d("permissions: $t") }
            try { startConnectivity() } catch (t: Throwable) { Log.d("connectivity: $t") }
            try { startPower() } catch (t: Throwable) { Log.d("power: $t") }
        }
        worker.postDelayed(jankTick, JANK_WINDOW_MS)
    }

    // ------------------------------------------------------------------ activity hooks (main thread)

    fun onActivityPreCreated(a: Activity) { createdAt[a] = SystemClock.uptimeMillis() }

    fun onActivityCreated(a: Activity, restored: Boolean, appInBackground: Boolean) {
        val t0 = createdAt[a] ?: SystemClock.uptimeMillis().also { createdAt[a] = it }
        val warm = appInBackground && !coldStartPending && !firstForeground
        if (!restored) intentSignals(a.intent)
        a.window?.let { w ->
            whenDrawn(w) {
                val now = SystemClock.uptimeMillis()
                if (coldStartPending) {
                    coldStartPending = false
                    val d = now - Process.getStartUptimeMillis()
                    if (d in 1..60_000) emit(Events.signal("app_start", clock()).put("kind", "cold").put("duration", d))
                } else if (warm) {
                    emit(Events.signal("app_start", clock()).put("kind", "warm").put("duration", now - t0))
                }
                emit(Events.signal("screen_load", clock()).put("screen", screen() ?: a.javaClass.simpleName).put("duration", now - t0))
            }
            frameMetrics(w)
        }
    }

    fun onActivityResumed(a: Activity) {
        a.window?.peekDecorView()?.let { keyboard(it) }
        worker.post { try { checkPermissions() } catch (t: Throwable) { Log.d("permissions: $t") } }
    }

    fun onActivityDestroyed(a: Activity) {
        createdAt.remove(a)
        val w = a.window ?: return
        frameListeners.remove(w)?.let { if (Build.VERSION.SDK_INT >= 24) try { w.removeOnFrameMetricsAvailableListener(it) } catch (_: Throwable) {} }
    }

    /** A screen (fragment, `ReplayIQ.screen`) started inside [a]: its load ends at the next frame. */
    fun onScreen(a: Activity?, name: String) {
        val w = a?.window ?: return
        val t0 = SystemClock.uptimeMillis()
        whenDrawn(w) { emit(Events.signal("screen_load", clock()).put("screen", name).put("duration", SystemClock.uptimeMillis() - t0)) }
    }

    fun onForeground() {
        emit(Events.signal("lifecycle", clock()).put("state", "foreground").put("cold", firstForeground))
        firstForeground = false
        startWatchdog()
    }

    fun onBackground() {
        emit(Events.signal("lifecycle", clock()).put("state", "background").put("cold", false))
        watchdog?.active = false
        watchdog = null
    }

    /** Runs [block] once, right after the next frame of [w] is drawn. */
    private fun whenDrawn(w: Window, block: () -> Unit) {
        val decor = w.peekDecorView() ?: w.decorView
        val vto = decor.viewTreeObserver
        if (!vto.isAlive) return
        var fired = false
        lateinit var listener: ViewTreeObserver.OnDrawListener
        listener = ViewTreeObserver.OnDrawListener {
            if (fired) return@OnDrawListener
            fired = true
            main.post { if (decor.viewTreeObserver.isAlive) decor.viewTreeObserver.removeOnDrawListener(listener) }
            main.postAtFrontOfQueue { try { block() } catch (t: Throwable) { Log.d("signal failed: $t") } }
        }
        vto.addOnDrawListener(listener)
    }

    // ------------------------------------------------------------------ intents: deeplink / push_open

    fun intentSignals(intent: Intent?) {
        intent ?: return
        val data = intent.data
        if (intent.action == Intent.ACTION_VIEW && data != null) {
            emit(Events.signal("deeplink", clock()).put("url", Events.sanitizeUrl(data.toString(), keepQuery)))
        }
        val extras = try { intent.extras } catch (_: Throwable) { null } ?: return
        if (extras.containsKey("google.message_id") || extras.containsKey("gcm.n.e") || extras.containsKey(PUSH_EXTRA)) {
            val campaign = extras.getString(PUSH_EXTRA) ?: extras.getString("google.c.a.c_l") ?: extras.getString("campaign")
                ?: extras.getString("utm_campaign") ?: ""
            pushOpen(campaign)
        }
    }

    fun pushOpen(campaign: String) = emit(Events.signal("push_open", clock()).put("campaign", campaign.take(200)))

    fun permission(name: String, result: String) =
        emit(Events.signal("permission", clock()).put("name", name.substringAfterLast('.')).put("result", result))

    // ------------------------------------------------------------------ jank (FrameMetrics, API 24+)

    private var dropped = 0
    private var frozen = 0
    private var worst = 0.0
    private val jankTick = object : Runnable {
        override fun run() {
            if (dropped > 0 || frozen > 0) {
                emit(Events.signal("jank", clock()).put("screen", screen() ?: "").put("dropped", dropped).put("frozen", frozen)
                    .put("worst", DomNode.r1(worst.toFloat())).put("window", JANK_WINDOW_MS))
            }
            dropped = 0; frozen = 0; worst = 0.0
            worker.postDelayed(this, JANK_WINDOW_MS)
        }
    }

    private fun frameMetrics(w: Window) {
        if (Build.VERSION.SDK_INT < 24 || frameListeners.containsKey(w)) return
        val l = Window.OnFrameMetricsAvailableListener { _, m, _ ->
            if (Build.VERSION.SDK_INT >= 26 && m.getMetric(FrameMetrics.FIRST_DRAW_FRAME) == 1L) return@OnFrameMetricsAvailableListener
            val ms = m.getMetric(FrameMetrics.TOTAL_DURATION) / 1_000_000.0
            Stats.frame(ms)
            // Called on the worker thread, like jankTick.
            if (ms > 16.7) dropped++
            if (ms > 700) frozen++
            if (ms > worst) worst = ms
        }
        try { w.addOnFrameMetricsAvailableListener(l, worker); frameListeners[w] = l } catch (t: Throwable) { Log.d("frame metrics: $t") }
    }

    // ------------------------------------------------------------------ hang: main thread blocked ≥ 2 s

    private var watchdog: Watchdog? = null
    @Volatile private var lastPong = SystemClock.uptimeMillis()
    @Volatile private var hangStack: String? = null

    private val pong = Runnable {
        val now = SystemClock.uptimeMillis()
        val gap = now - lastPong
        lastPong = now
        if (gap >= HANG_MS) {
            emit(Events.signal("hang", clock()).put("duration", gap).put("stack", (hangStack ?: "").take(16_000)))
            hangStack = null
        }
    }

    private fun startWatchdog() {
        if (watchdog != null) return
        lastPong = SystemClock.uptimeMillis()
        watchdog = Watchdog().also { it.start() }
    }

    private inner class Watchdog : Thread("ReplayIQ-watchdog") {
        @Volatile var active = true
        init { isDaemon = true; priority = MIN_PRIORITY }
        override fun run() {
            while (active) {
                main.post(pong)
                try { sleep(PING_MS) } catch (_: InterruptedException) { return }
                if (hangStack == null && SystemClock.uptimeMillis() - lastPong >= HANG_MS) {
                    hangStack = try { Looper.getMainLooper().thread.stackTrace.joinToString("\n") { "\tat $it" } } catch (_: Throwable) { "" }
                }
            }
        }
    }

    // ------------------------------------------------------------------ memory / orientation

    private var lastOrientation = Configuration.ORIENTATION_UNDEFINED

    private val componentCallbacks = object : ComponentCallbacks2 {
        override fun onTrimMemory(level: Int) {
            @Suppress("DEPRECATION")
            val l = when (level) {
                ComponentCallbacks2.TRIM_MEMORY_RUNNING_MODERATE, ComponentCallbacks2.TRIM_MEMORY_RUNNING_LOW -> "warning"
                ComponentCallbacks2.TRIM_MEMORY_RUNNING_CRITICAL -> "critical"
                else -> return
            }
            memory(l)
        }

        override fun onLowMemory() = memory("critical")

        override fun onConfigurationChanged(c: Configuration) {
            if (c.orientation == lastOrientation || c.orientation == Configuration.ORIENTATION_UNDEFINED) return
            lastOrientation = c.orientation
            emit(Events.signal("orientation", clock()).put("value", if (c.orientation == Configuration.ORIENTATION_LANDSCAPE) "landscape" else "portrait"))
        }
    }

    private fun memory(level: String) {
        val rt = Runtime.getRuntime()
        val used = (rt.totalMemory() - rt.freeMemory() + Debug.getNativeHeapAllocatedSize()) / (1024 * 1024)
        emit(Events.signal("memory", clock()).put("level", level).put("used", used))
    }

    // ------------------------------------------------------------------ keyboard

    private var keyboardVisible = false

    private fun keyboard(decor: View) {
        if (keyboardRoots.containsKey(decor)) return
        val vto = decor.viewTreeObserver
        if (!vto.isAlive) return
        keyboardRoots[decor] = true
        val r = Rect()
        vto.addOnGlobalLayoutListener {
            try {
                val d = decor.resources.displayMetrics.density
                val visible: Boolean
                val height: Int
                if (Build.VERSION.SDK_INT >= 30) {
                    val insets = decor.rootWindowInsets ?: return@addOnGlobalLayoutListener
                    visible = insets.isVisible(WindowInsets.Type.ime())
                    height = (insets.getInsets(WindowInsets.Type.ime()).bottom / d).toInt()
                } else {
                    decor.getWindowVisibleDisplayFrame(r)
                    val diff = decor.rootView.height - r.bottom
                    visible = diff > decor.rootView.height * 0.15f
                    height = if (visible) (diff / d).toInt() else 0
                }
                if (visible != keyboardVisible) {
                    keyboardVisible = visible
                    emit(Events.signal("keyboard", clock()).put("visible", visible).put("height", height))
                }
            } catch (t: Throwable) { Log.d("keyboard: $t") }
        }
    }

    // ------------------------------------------------------------------ connectivity (needs ACCESS_NETWORK_STATE)

    private var lastNet: String? = null

    private fun startConnectivity() {
        if (Build.VERSION.SDK_INT < 24) return
        if (app.checkPermission(Manifest.permission.ACCESS_NETWORK_STATE, Process.myPid(), Process.myUid()) != PackageManager.PERMISSION_GRANTED) {
            Log.d("connectivity signals off: ACCESS_NETWORK_STATE not granted")
            return
        }
        val cm = app.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return
        cm.registerDefaultNetworkCallback(object : ConnectivityManager.NetworkCallback() {
            override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) {
                val type = when {
                    caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
                    caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
                    caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
                    else -> "other"
                }
                val kbps = caps.linkDownstreamBandwidthKbps
                val quality = when {
                    !caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) -> "poor"
                    kbps >= 10_000 -> "good"
                    kbps >= 1_500 -> "moderate"
                    else -> "poor"
                }
                net(type, quality)
            }

            override fun onLost(network: Network) = net("none", "none")
        }, worker)
    }

    private fun net(type: String, quality: String) {
        val key = "$type/$quality"
        if (key == lastNet) return
        lastNet = key
        // Spec v1.1 calls this field `type`, which collides with the event's own `type: 5`: sent as `network`.
        emit(Events.signal("connectivity", clock()).put("network", type).put("quality", quality))
    }

    // ------------------------------------------------------------------ permissions (worker)

    private var dangerous: List<String> = emptyList()
    private var permState: Map<String, String>? = null

    private fun loadPermissions() {
        val pm = app.packageManager
        @Suppress("DEPRECATION")
        val info: PackageInfo = pm.getPackageInfo(app.packageName, PackageManager.GET_PERMISSIONS)
        dangerous = (info.requestedPermissions ?: emptyArray()).filter { p ->
            try {
                val pi = pm.getPermissionInfo(p, 0)
                @Suppress("DEPRECATION")
                val base = if (Build.VERSION.SDK_INT >= 28) pi.protection else pi.protectionLevel and PermissionInfo.PROTECTION_MASK_BASE
                base == PermissionInfo.PROTECTION_DANGEROUS
            } catch (_: Exception) { false }
        }
        permState = currentPermissions()
    }

    private fun currentPermissions(): Map<String, String> {
        val granted = dangerous.associateWith {
            if (app.checkPermission(it, Process.myPid(), Process.myUid()) == PackageManager.PERMISSION_GRANTED) "granted" else "denied"
        }.toMutableMap()
        // Android 14 partial photo access.
        val selected = granted["android.permission.READ_MEDIA_VISUAL_USER_SELECTED"]
        if (selected == "granted") {
            for (p in listOf("android.permission.READ_MEDIA_IMAGES", "android.permission.READ_MEDIA_VIDEO")) if (granted[p] == "denied") granted[p] = "limited"
        }
        return granted
    }

    private fun checkPermissions() {
        val before = permState ?: return
        val now = currentPermissions()
        for ((p, r) in now) if (before[p] != r && p != "android.permission.READ_MEDIA_VISUAL_USER_SELECTED") permission(p, r)
        permState = now
    }

    // ------------------------------------------------------------------ thermal / power

    private fun startPower() {
        val pm = app.getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return
        if (Build.VERSION.SDK_INT >= 29) {
            var last = pm.currentThermalStatus
            pm.addThermalStatusListener({ worker.post(it) }) { status ->
                if (status == last) return@addThermalStatusListener
                last = status
                val s = when (status) {
                    PowerManager.THERMAL_STATUS_NONE -> "none"
                    PowerManager.THERMAL_STATUS_LIGHT -> "light"
                    PowerManager.THERMAL_STATUS_MODERATE -> "moderate"
                    PowerManager.THERMAL_STATUS_SEVERE -> "severe"
                    PowerManager.THERMAL_STATUS_CRITICAL -> "critical"
                    PowerManager.THERMAL_STATUS_EMERGENCY -> "emergency"
                    else -> "shutdown"
                }
                emit(Events.signal("thermal", clock()).put("state", s))
            }
        }
        var lowPower = pm.isPowerSaveMode
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(c: Context, i: Intent) {
                val now = pm.isPowerSaveMode
                if (now == lowPower) return
                lowPower = now
                emit(Events.signal("power", clock()).put("low_power", now))
            }
        }
        val filter = IntentFilter(PowerManager.ACTION_POWER_SAVE_MODE_CHANGED)
        if (Build.VERSION.SDK_INT >= 33) app.registerReceiver(receiver, filter, null, worker, Context.RECEIVER_NOT_EXPORTED)
        else app.registerReceiver(receiver, filter, null, worker)
    }

    companion object {
        /** Intent extra apps can set on a notification's intent: `ReplayIQ` reports `push_open` with it as the campaign. */
        const val PUSH_EXTRA = "replayiq_push_campaign"
        private const val JANK_WINDOW_MS = 5_000L
        private const val HANG_MS = 2_000L
        private const val PING_MS = 500L
    }
}
