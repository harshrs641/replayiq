package com.replayiq.android.internal

import android.app.Activity
import android.graphics.Rect
import android.text.InputType
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import com.replayiq.android.ReplayIQ
import com.replayiq.android.ReplayIQOptions
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class ViewInspectorTest {
    private lateinit var activity: Activity
    private lateinit var root: LinearLayout
    private val inspector = ViewInspector(ReplayIQOptions())

    @Before fun setUp() {
        activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        root = LinearLayout(activity).apply { orientation = LinearLayout.VERTICAL }
        activity.setContentView(root, ViewGroup.LayoutParams(1080, 2400))
    }

    private fun <T : View> add(v: T, h: Int = 100): T {
        root.addView(v, LinearLayout.LayoutParams(1080, h)); return v
    }

    private fun layout() {
        val decor = activity.window.decorView
        decor.measure(View.MeasureSpec.makeMeasureSpec(1080, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(2400, View.MeasureSpec.EXACTLY))
        decor.layout(0, 0, 1080, 2400)
    }

    private fun masks(): List<Rect> = ArrayList<Rect>().also { inspector.collectMasks(activity.window.decorView, it) }

    @Test fun masksInputsPasswordsAndTaggedViewsByDefault() {
        add(TextView(activity).apply { text = "Hello" })
        val card = add(EditText(activity).apply { setText("4242 4242 4242 4242") })
        val pin = add(TextView(activity).apply { inputType = InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_VARIATION_PASSWORD })
        val tagged = add(TextView(activity).apply { text = "secret"; tag = "replayiq-mask" })
        val viaApi = add(FrameLayout(activity).apply { addView(TextView(activity).apply { text = "IBAN" }) })
        ReplayIQ.mask(viaApi)
        layout()
        val rects = masks()
        assertEquals(4, rects.size)
        for (v in listOf(card, pin, tagged, viaApi)) {
            val r = Rect(); v.getGlobalVisibleRect(r)
            assertTrue("$v masked", rects.contains(r))
        }
    }

    @Test fun unmaskRecordsAnInputButNeverAPassword() {
        val promo = add(EditText(activity))
        val pwd = add(EditText(activity).apply { inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD })
        ReplayIQ.unmask(promo); ReplayIQ.unmask(pwd)
        layout()
        assertFalse(inspector.isMasked(promo))
        assertTrue(inspector.isMasked(pwd))
        assertEquals(1, masks().size)
    }

    @Test fun optionalRulesMaskAllTextAndImages() {
        val strict = ViewInspector(ReplayIQOptions.Builder().maskAllText(true).maskAllImages(true).maskAllInputs(false).build())
        assertTrue(strict.isMasked(TextView(activity)))
        assertTrue(strict.isMasked(ImageView(activity)))
        assertTrue("maskAllText covers inputs too", strict.isMasked(EditText(activity)))
        assertFalse(inspector.isMasked(TextView(activity)))
    }

    @Test fun invisibleViewsAreSkipped() {
        add(EditText(activity)).visibility = View.GONE
        layout()
        assertTrue(masks().isEmpty())
    }

    @Test fun selectorsUseRoleAndVisibleLabel() {
        val pay = add(Button(activity).apply { text = "Pay now"; setOnClickListener {} })
        val icon = add(ImageView(activity).apply { contentDescription = "Close"; setOnClickListener {} })
        val row = add(LinearLayout(activity).apply { setOnClickListener {}; addView(TextView(activity).apply { text = "Shipping" }) })
        layout()
        assertEquals("button:\"Pay now\"", inspector.selectorFor(pay))
        assertEquals("button:\"Close\"", inspector.selectorFor(icon))
        assertEquals("button:\"Shipping\"", inspector.selectorFor(row))
        val r = Rect(); row.getGlobalVisibleRect(r)
        assertEquals("button:\"Shipping\"", inspector.selectorAt(activity.window.decorView, r.centerX(), r.centerY()))
    }

    @Test fun inputSelectorsNeverContainTheValue() {
        val card = add(EditText(activity).apply { hint = "Card number"; setText("4242424242424242") })
        val noHint = add(EditText(activity).apply { id = View.generateViewId(); setText("4242424242424242") })
        val maskedLabel = add(TextView(activity).apply { text = "Secret balance"; tag = "replayiq-mask"; setOnClickListener {} })
        layout()
        assertEquals("input:\"Card number\"", inspector.selectorFor(card))
        assertFalse(inspector.selectorFor(noHint).contains("4242"))
        assertFalse(inspector.selectorFor(maskedLabel).contains("Secret"))
    }

    @Test fun labelsAreCleanedAndTruncated() {
        assertEquals("button:\"say 'hi' now\"", ViewInspector.selector("button", "say \"hi\"\nnow"))
        assertEquals(60, ViewInspector.clean("x".repeat(100)).length)
    }

    @Test fun tapsIgnoreDebugOverlaysAndNeverUseClassNames() {
        val button = add(FrameLayout(activity).apply {
            isClickable = true
            addView(TextView(activity).apply { text = "Pay now" })
        }, 200)
        // A full-screen overlay drawn on top, like React Native's DebuggingOverlay.
        (activity.window.decorView as ViewGroup).addView(
            com.replayiq.android.internal.fake.DebuggingOverlay(activity), ViewGroup.LayoutParams(1080, 2400))
        val unlabelled = add(FrameLayout(activity).apply { isClickable = true }, 200)
        layout()
        val r = Rect(); button.getGlobalVisibleRect(r)
        assertEquals("button:\"Pay now\"", inspector.selectorAt(activity.window.decorView, r.centerX(), r.centerY()))
        unlabelled.getGlobalVisibleRect(r)
        assertEquals("button", inspector.selectorAt(activity.window.decorView, r.centerX(), r.centerY()))
    }

    @Test fun tapsUseTheNearestAccessibilityLabelWhenNothingIsClickable() {
        // React Native: a Pressable is a focusable view with a content description, not clickable.
        val pressable = add(FrameLayout(activity).apply {
            isFocusable = true
            contentDescription = "Pay now"
            addView(TextView(activity).apply { text = "Pay now" })
        }, 200)
        layout()
        val r = Rect(); pressable.getGlobalVisibleRect(r)
        assertEquals("button:\"Pay now\"", inspector.selectorAt(activity.window.decorView, r.centerX(), r.centerY()))
    }

    @Test fun tapsPassThroughEmptyFullScreenContainers() {
        val button = add(Button(activity).apply { text = "Pay now" }, 200)
        // A transparent, non-clickable container on top (React Native box-none wrapper / LogBox).
        (activity.window.decorView as ViewGroup).addView(FrameLayout(activity), ViewGroup.LayoutParams(1080, 2400))
        layout()
        val r = Rect(); button.getGlobalVisibleRect(r)
        assertEquals("button:\"Pay now\"", inspector.selectorAt(activity.window.decorView, r.centerX(), r.centerY()))
    }
}
