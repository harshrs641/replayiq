package com.replayiq.android.internal

import android.app.Application
import android.graphics.Color
import android.graphics.Typeface
import android.os.Handler
import android.os.Looper
import android.text.SpannableString
import android.text.Spanned
import android.text.style.AbsoluteSizeSpan
import android.text.style.ForegroundColorSpan
import android.text.style.StyleSpan
import android.view.View
import android.widget.FrameLayout
import android.widget.TextView
import androidx.test.core.app.ApplicationProvider
import com.facebook.react.uimanager.drawable.CompositeBackgroundDrawable
import com.replayiq.android.ReplayIQOptions
import com.replayiq.android.internal.fake.DebuggingOverlay
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class ReactNativeDomTest {
    @get:Rule val tmp = TemporaryFolder()
    private val ctx: Application = ApplicationProvider.getApplicationContext()

    private fun walk(root: View): WalkResult {
        root.measure(View.MeasureSpec.makeMeasureSpec(400, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(800, View.MeasureSpec.EXACTLY))
        root.layout(0, 0, 400, 800)
        val o = ReplayIQOptions()
        val assets = AssetStore(tmp.newFolder(), DiskQueue(tmp.newFolder()))
        return ViewWalker(o, ViewInspector(o), DrawableAssets(assets, Handler(Looper.getMainLooper()), 80) {}) { null }.walk(root)
    }

    private fun find(n: DomNode, p: (DomNode) -> Boolean): DomNode? {
        if (p(n)) return n
        for (c in n.c) find(c, p)?.let { return it }
        return null
    }

    @Test fun rnBackgroundIsDescribedNotRasterised() {
        val card = FrameLayout(ctx).apply {
            background = CompositeBackgroundDrawable(0xFFEEF2FF.toInt(), mapOf("ALL" to 1f), mapOf("ALL" to 0xFFC7D2FE.toInt()), 10f)
        }
        val root = FrameLayout(ctx).apply { addView(card, FrameLayout.LayoutParams(300, 100)) }
        val n = walk(root).root.c.single()
        val s = n.ownJson().getJSONObject("s")
        assertEquals("#FFEEF2FF", s.getString("bg"))
        assertEquals(1.0, s.getDouble("bw"), 0.01)
        assertEquals("#FFC7D2FE", s.getString("bc"))
        assertEquals("[10,10,10,10]", s.getJSONArray("r").toString())
        assertEquals("view", n.k)
        assertNull(find(n) { it.k == "image" }) // nothing rasterised
    }

    @Test fun rnBottomBorderBecomesALine() {
        val row = FrameLayout(ctx).apply {
            background = CompositeBackgroundDrawable(Color.WHITE, mapOf("BOTTOM" to 1f), mapOf("ALL" to 0xFFE5E7EB.toInt()))
        }
        val root = FrameLayout(ctx).apply { addView(row, FrameLayout.LayoutParams(400, 60)) }
        val n = walk(root).root.c.single()
        assertFalse(n.ownJson().getJSONObject("s").has("bw"))
        val line = n.c.single()
        assertEquals(0f, line.x); assertEquals(59f, line.y, 0.01f); assertEquals(400f, line.w); assertEquals(1f, line.h, 0.01f)
        assertEquals(0xFFE5E7EB.toInt(), line.bg)
    }

    @Test fun debugOverlayIsSkippedSoTheScreenIsNotAnIsland() {
        val root = FrameLayout(ctx).apply {
            addView(TextView(ctx).apply { text = "Checkout" })
            addView(DebuggingOverlay(ctx), FrameLayout.LayoutParams(400, 800))
        }
        val r = walk(root)
        assertEquals(0f, r.islandArea)
        assertEquals(1, r.root.c.size)
    }

    @Test fun textStyleComesFromSpans() {
        val s = SpannableString("Checkout").apply {
            setSpan(AbsoluteSizeSpan(28, true), 0, length, Spanned.SPAN_INCLUSIVE_INCLUSIVE)
            setSpan(ForegroundColorSpan(0xFF111827.toInt()), 0, length, Spanned.SPAN_INCLUSIVE_INCLUSIVE)
            setSpan(StyleSpan(Typeface.BOLD), 0, length, Spanned.SPAN_INCLUSIVE_INCLUSIVE)
        }
        val root = FrameLayout(ctx).apply { addView(TextView(ctx).apply { text = s; textSize = 14f }) }
        val tx = find(walk(root).root) { it.tx != null }!!.tx!!
        assertEquals("Checkout", tx.v)
        assertEquals(28f, tx.size, 0.5f)
        assertEquals(0xFF111827.toInt(), tx.color)
        assertEquals(700, tx.weight)
    }
}
