package com.replayiq.android.internal

import android.app.Activity
import android.os.SystemClock
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.FrameLayout
import com.replayiq.android.ReplayIQOptions
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class TouchTrackerTest {
    private lateinit var activity: Activity
    private val events = ArrayList<JSONObject>()
    private var now = 1_000L
    private lateinit var tracker: TouchTracker
    private lateinit var density: Number

    @Before fun setUp() {
        activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        val root = FrameLayout(activity)
        root.addView(Button(activity).apply { text = "Pay now"; setOnClickListener {} }, FrameLayout.LayoutParams(400, 200))
        activity.setContentView(root, ViewGroup.LayoutParams(1080, 2400))
        val decor = activity.window.decorView
        decor.measure(View.MeasureSpec.makeMeasureSpec(1080, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(2400, View.MeasureSpec.EXACTLY))
        decor.layout(0, 0, 1080, 2400)
        density = activity.resources.displayMetrics.density
        tracker = TouchTracker(ViewInspector(ReplayIQOptions()), { events.add(it) }, { now })
        tracker.install(activity.window)
    }

    private fun send(action: Int, x: Float, y: Float) {
        val ev = MotionEvent.obtain(SystemClock.uptimeMillis(), SystemClock.uptimeMillis(), action, x, y, 0)
        activity.window.callback.dispatchTouchEvent(ev)
        ev.recycle()
    }

    private fun tap(x: Float, y: Float) { send(MotionEvent.ACTION_DOWN, x, y); now += 50; send(MotionEvent.ACTION_UP, x, y); now += 100 }

    private fun subtypes() = events.map { it.getString("subtype") }

    @Test fun recordsTouchPhasesInDpAndThrottlesMoves() {
        send(MotionEvent.ACTION_DOWN, 600f, 1000f)
        repeat(10) { now += 10; send(MotionEvent.ACTION_MOVE, 600f + it * 20, 1000f) } // 100 ms of moves
        send(MotionEvent.ACTION_UP, 800f, 1000f)
        val touches = events.filter { it.getString("subtype") == "touch" }
        assertEquals("down", touches.first().getString("phase"))
        assertEquals("up", touches.last().getString("phase"))
        val moves = touches.count { it.getString("phase") == "move" }
        assertTrue("moves throttled to 50 ms, got $moves", moves in 2..3)
        assertEquals(Math.round(600f / density.toFloat()), touches.first().getInt("x"))
        assertTrue("a drag is not a click", "click" !in subtypes())
    }

    @Test fun tapsBecomeClicksWithTheTouchedViewSelector() {
        tap(100f, 100f)
        val click = events.first { it.getString("subtype") == "click" }
        assertEquals("button:\"Pay now\"", click.getString("selector"))
    }

    @Test fun threeQuickTapsAreARageClick() {
        repeat(3) { tap(100f, 100f) }
        val rage = events.filter { it.getString("subtype") == "rage_click" }
        assertEquals(1, rage.size)
        assertEquals("button:\"Pay now\"", rage[0].getString("selector"))
        assertEquals(3, events.count { it.getString("subtype") == "click" })
    }

    @Test fun installsOnceAndStillForwardsToTheApp() {
        var clicked = 0
        (activity.window.decorView.findViewById<ViewGroup>(android.R.id.content).getChildAt(0) as ViewGroup)
            .getChildAt(0).setOnClickListener { clicked++ }
        tracker.install(activity.window)
        tap(100f, 100f)
        org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idle()
        assertEquals(1, clicked)
        assertEquals(1, events.count { it.getString("subtype") == "click" })
    }
}
