package com.replayiq.android.internal

import android.annotation.SuppressLint
import android.annotation.TargetApi
import android.os.Build
import android.view.ActionMode
import android.view.KeyEvent
import android.view.KeyboardShortcutGroup
import android.view.Menu
import android.view.MenuItem
import android.view.MotionEvent
import android.view.SearchEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.Window
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import org.json.JSONObject
import java.util.WeakHashMap
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * Touches (down / move every ≥50 ms / up), taps as `click` and bursts of taps as `rage_click`,
 * read in a Window.Callback wrapper so the app's own handling is untouched. Main thread only.
 */
internal class TouchTracker(
    private val inspector: ViewInspector,
    private val emit: (JSONObject) -> Unit,
    private val clock: () -> Long = System::currentTimeMillis,
) {
    private val installed = WeakHashMap<Window, Boolean>()
    private val moveThrottle = Throttle(MOVE_INTERVAL_MS)
    private val rage = RageClickDetector()
    @Volatile var enabled = true

    private var downX = 0f
    private var downY = 0f
    private var downAt = 0L
    private var tapCandidate = false
    private var multiTouch = false
    private var pinchStart = 0f
    private var pinchScale = 1f
    private var lastTapAt = Long.MIN_VALUE
    private var lastTapX = 0f
    private var lastTapY = 0f

    fun install(window: Window) {
        if (installed[window] == true) return
        val current = window.callback ?: return
        window.callback = Wrapper(current, window)
        installed[window] = true
    }

    internal fun onTouch(window: Window, ev: MotionEvent) {
        if (!enabled) return
        val decor = window.peekDecorView() ?: return
        val density = decor.resources.displayMetrics.density
        val now = clock()
        // Coordinates relative to the window (= decor view = the screenshot).
        val x = ev.x
        val y = ev.y
        val xDp = (x / density).roundToInt()
        val yDp = (y / density).roundToInt()
        when (ev.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                moveThrottle.reset()
                downX = x; downY = y; downAt = now; tapCandidate = true; multiTouch = false; pinchScale = 1f
                emit(Events.touch(now, xDp, yDp, "down"))
            }
            MotionEvent.ACTION_MOVE -> {
                val slop = ViewConfiguration.get(decor.context).scaledTouchSlop
                if (abs(x - downX) > slop || abs(y - downY) > slop) tapCandidate = false
                if (ev.pointerCount >= 2 && pinchStart > 0f) pinchScale = spread(ev) / pinchStart
                if (moveThrottle.allow(now)) emit(Events.touch(now, xDp, yDp, "move"))
            }
            MotionEvent.ACTION_POINTER_DOWN -> {
                tapCandidate = false
                multiTouch = true
                if (ev.pointerCount == 2) pinchStart = spread(ev)
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                emit(Events.touch(now, xDp, yDp, "up"))
                if (ev.actionMasked == MotionEvent.ACTION_UP) gesture(decor, ev, now, x, y, density)
                tapCandidate = false
                pinchStart = 0f
            }
        }
    }

    private fun spread(ev: MotionEvent): Float {
        if (ev.pointerCount < 2) return 0f
        return kotlin.math.hypot(ev.getX(0) - ev.getX(1), ev.getY(0) - ev.getY(1))
    }

    /** `gesture` (v1.1 §2): tap / double_tap / long_press / swipe / pan / pinch. Taps also send `click`. */
    private fun gesture(decor: View, ev: MotionEvent, now: Long, x: Float, y: Float, density: Float) {
        val dur = now - downAt
        val dxDp = (x - downX) / density
        val dyDp = (y - downY) / density
        val sel = { inspector.dragSelectorAt(decor, downX.roundToInt(), downY.roundToInt()) }
        when {
            multiTouch -> if (abs(pinchScale - 1f) > 0.1f) emit(Events.gesture(now, "pinch", sel(), downX / density, downY / density, scale = pinchScale))
            tapCandidate -> {
                val longPress = dur >= ViewConfiguration.getLongPressTimeout()
                val double = !longPress && lastTapAt != Long.MIN_VALUE && now - lastTapAt <= ViewConfiguration.getDoubleTapTimeout() + 100 &&
                    kotlin.math.hypot((x - lastTapX) / density, (y - lastTapY) / density) <= 48f
                val selector = onTap(decor, now, downX, downY, density)
                emit(Events.gesture(now, if (longPress) "long_press" else if (double) "double_tap" else "tap", selector, downX / density, downY / density))
                lastTapAt = if (double) Long.MIN_VALUE else now
                lastTapX = x; lastTapY = y
            }
            else -> {
                val dist = kotlin.math.hypot(dxDp, dyDp)
                val fast = dur > 0 && dist / dur * 1000f > SWIPE_DP_PER_S && dur < 500
                emit(Events.gesture(now, if (fast) "swipe" else "pan", sel(), downX / density, downY / density, dxDp, dyDp))
            }
        }
    }

    private fun onTap(decor: View, now: Long, x: Float, y: Float, density: Float): String {
        val selector = inspector.selectorAt(decor, x.roundToInt(), y.roundToInt()) ?: "view:\"Window\""
        emit(Events.click(now, selector))
        val xDp = x / density
        val yDp = y / density
        if (rage.onTap(now, xDp, yDp)) emit(Events.rageClick(now, selector, xDp.roundToInt(), yDp.roundToInt()))
        return selector
    }

    /** Forwards everything to the app's callback; only looks at touches on the way. */
    private inner class Wrapper(private val d: Window.Callback, private val window: Window) : Window.Callback {
        override fun dispatchTouchEvent(event: MotionEvent): Boolean {
            try { onTouch(window, event) } catch (t: Throwable) { Log.w("touch tracking failed", t) }
            return d.dispatchTouchEvent(event)
        }

        override fun dispatchKeyEvent(event: KeyEvent) = d.dispatchKeyEvent(event)
        override fun dispatchKeyShortcutEvent(event: KeyEvent) = d.dispatchKeyShortcutEvent(event)
        override fun dispatchTrackballEvent(event: MotionEvent) = d.dispatchTrackballEvent(event)
        override fun dispatchGenericMotionEvent(event: MotionEvent) = d.dispatchGenericMotionEvent(event)
        override fun dispatchPopulateAccessibilityEvent(event: AccessibilityEvent) = d.dispatchPopulateAccessibilityEvent(event)
        override fun onCreatePanelView(featureId: Int): View? = d.onCreatePanelView(featureId)
        override fun onCreatePanelMenu(featureId: Int, menu: Menu) = d.onCreatePanelMenu(featureId, menu)
        override fun onPreparePanel(featureId: Int, view: View?, menu: Menu) = d.onPreparePanel(featureId, view, menu)
        override fun onMenuOpened(featureId: Int, menu: Menu) = d.onMenuOpened(featureId, menu)
        override fun onMenuItemSelected(featureId: Int, item: MenuItem) = d.onMenuItemSelected(featureId, item)
        override fun onWindowAttributesChanged(attrs: WindowManager.LayoutParams) = d.onWindowAttributesChanged(attrs)
        override fun onContentChanged() = d.onContentChanged()
        override fun onWindowFocusChanged(hasFocus: Boolean) = d.onWindowFocusChanged(hasFocus)
        override fun onAttachedToWindow() = d.onAttachedToWindow()
        override fun onDetachedFromWindow() = d.onDetachedFromWindow()
        override fun onPanelClosed(featureId: Int, menu: Menu) = d.onPanelClosed(featureId, menu)
        override fun onSearchRequested() = d.onSearchRequested()
        override fun onSearchRequested(searchEvent: SearchEvent) = d.onSearchRequested(searchEvent)
        override fun onWindowStartingActionMode(callback: ActionMode.Callback): ActionMode? = d.onWindowStartingActionMode(callback)
        override fun onWindowStartingActionMode(callback: ActionMode.Callback, type: Int): ActionMode? =
            d.onWindowStartingActionMode(callback, type)
        override fun onActionModeStarted(mode: ActionMode) = d.onActionModeStarted(mode)
        override fun onActionModeFinished(mode: ActionMode) = d.onActionModeFinished(mode)

        @SuppressLint("NewApi")
        override fun onProvideKeyboardShortcuts(data: MutableList<KeyboardShortcutGroup>, menu: Menu?, deviceId: Int) =
            d.onProvideKeyboardShortcuts(data, menu, deviceId)

        @TargetApi(Build.VERSION_CODES.O)
        override fun onPointerCaptureChanged(hasCapture: Boolean) = d.onPointerCaptureChanged(hasCapture)
    }

    private companion object {
        const val MOVE_INTERVAL_MS = 50L
        const val SWIPE_DP_PER_S = 600f
    }
}
