package com.replayiq.android.internal

import android.app.Application
import android.graphics.Color
import android.graphics.drawable.ColorDrawable
import android.os.Handler
import android.os.Looper
import android.text.InputType
import android.view.View
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import androidx.test.core.app.ApplicationProvider
import com.replayiq.android.ReplayIQ
import com.replayiq.android.ReplayIQOptions
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.util.concurrent.TimeUnit

@RunWith(RobolectricTestRunner::class)
class NativeDomTest {
    @get:Rule val tmp = TemporaryFolder()

    private fun node(id: Int, k: String = "view", vararg kids: DomNode) =
        DomNode(id, k).frame(0f, 0f, 100f, 50f).also { it.c.addAll(kids) }

    // ---------------------------------------------------------------- serialisation

    @Test fun ownJsonRoundsAndOmitsDefaults() {
        val n = DomNode(7, "text").frame(16.04f, 120.26f, 361f, 56f)
        n.bg = 0xFF1F2937.toInt()
        n.radii = floatArrayOf(12f, 12f, 12f, 12f)
        n.tx = DomNode.TextInfo("Pay now", 17f, 600, false, Color.WHITE, "center", 22f, 1)
        val j = n.ownJson()
        assertEquals("[16,120.3,361,56]", j.getJSONArray("f").toString())
        assertEquals("#FF1F2937", j.getJSONObject("s").getString("bg"))
        assertFalse(j.getJSONObject("s").has("o"))
        assertEquals(600, j.getJSONObject("tx").getInt("w"))
        assertEquals("center", j.getJSONObject("tx").getString("al"))
        assertFalse(j.has("c"))
    }

    @Test fun islandWithoutPixelsHasHint_imageWithAssetHasImg() {
        assertEquals("map", DomNode(1, "island").also { it.hint = "map" }.ownJson().getString("hint"))
        val img = DomNode(2, "image").also { it.img = "ab".repeat(32); it.fit = "cover" }.ownJson().getJSONObject("img")
        assertEquals("cover", img.getString("fit"))
    }

    // ---------------------------------------------------------------- diff

    @Test fun mutationCarriesCompleteOwnFieldsOfChangedNodes() {
        val d = DomDiffer()
        val text = DomNode(3, "text").frame(0f, 0f, 50f, 20f).also { it.tx = DomNode.TextInfo("A", 14f, 400, false, Color.BLACK, null, 0f, 0) }
        d.snapshot(node(1, "view", node(2), text))
        val text2 = DomNode(3, "text").frame(0f, 0f, 50f, 20f).also { it.tx = DomNode.TextInfo("B", 14f, 400, false, Color.BLACK, null, 0f, 0) }
        val m = d.mutation(node(1, "view", node(2), text2))!!
        assertEquals(1, m.updates.length())
        val u = m.updates.getJSONObject(0)
        assertEquals(3, u.getInt("id"))
        assertEquals("text", u.getString("k"))          // whole node minus c
        assertEquals("[0,0,50,20]", u.getJSONArray("f").toString())
        assertEquals("B", u.getJSONObject("tx").getString("v"))
        assertEquals(0, m.adds.length())
        assertEquals(0, m.removes.length())
        assertTrue(d.mutation(node(1, "view", node(2), text2))!!.isEmpty)
    }

    @Test fun addsUseNextSiblingAndRemovesNameParent() {
        val d = DomDiffer()
        d.snapshot(node(1, "view", node(2), node(3)))
        val m = d.mutation(node(1, "view", node(4, "view", node(5)), node(3)))!!
        assertEquals(1, m.removes.length())
        assertEquals(JSONObject().put("p", 1).put("id", 2).toString(), m.removes.getJSONObject(0).toString())
        val add = m.adds.getJSONObject(0)
        assertEquals(1, add.getInt("p"))
        assertEquals(3, add.getInt("next"))
        assertEquals(5, add.getJSONObject("n").getJSONArray("c").getJSONObject(0).getInt("id"))
    }

    @Test fun reorderedChildIsMovedNotRebuiltWholesale() {
        val d = DomDiffer()
        d.snapshot(node(1, "view", node(2), node(3), node(4)))
        val m = d.mutation(node(1, "view", node(2), node(4), node(3)))!!
        // 2 and 4 stay; 3 moves to the end.
        assertEquals(1, m.removes.length())
        assertEquals(3, m.removes.getJSONObject(0).getInt("id"))
        assertEquals(1, m.adds.length())
        assertFalse(m.adds.getJSONObject(0).has("next"))
    }

    @Test fun imageGainingItsAssetIsReplaced() {
        val d = DomDiffer()
        d.snapshot(node(1, "view", DomNode(2, "image").frame(0f, 0f, 10f, 10f)))
        val m = d.mutation(node(1, "view", DomNode(2, "image").frame(0f, 0f, 10f, 10f).also { it.img = "cd".repeat(32) }))!!
        assertEquals(1, m.removes.length())
        assertEquals(1, m.adds.length())
        assertEquals(0, m.updates.length())
    }

    @Test fun newRootNeedsSnapshot_scrollOffsetChangeReported() {
        val d = DomDiffer()
        d.snapshot(node(1, "view", node(2, "scroll").also { it.so = floatArrayOf(0f, 0f) }))
        assertNull(d.mutation(node(9)))
        d.snapshot(node(1, "view", node(2, "scroll").also { it.so = floatArrayOf(0f, 0f) }))
        val m = d.mutation(node(1, "view", node(2, "scroll").also { it.so = floatArrayOf(0f, 340f) }))!!
        assertEquals("[0,340]", m.updates.getJSONObject(0).getJSONArray("so").toString())
        assertEquals(1, d.scrolled.size)
    }

    // ---------------------------------------------------------------- View walker

    private fun walker(options: ReplayIQOptions = ReplayIQOptions()): ViewWalker {
        val app: Application = ApplicationProvider.getApplicationContext()
        val assets = AssetStore(tmp.newFolder("assets"), DiskQueue(tmp.newFolder("q")))
        val main = Handler(Looper.getMainLooper())
        return ViewWalker(options, ViewInspector(options), DrawableAssets(assets, main, 80) {}) { null }
    }

    private fun layout(v: View, w: Int = 400, h: Int = 800) {
        v.measure(View.MeasureSpec.makeMeasureSpec(w, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(h, View.MeasureSpec.EXACTLY))
        v.layout(0, 0, w, h)
    }

    private fun find(n: DomNode, pred: (DomNode) -> Boolean): DomNode? {
        if (pred(n)) return n
        for (c in n.c) find(c, pred)?.let { return it }
        return null
    }

    @Test fun walkerNeverRecordsInputValuesOrMaskedContent() {
        val ctx: Application = ApplicationProvider.getApplicationContext()
        val root = LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            background = ColorDrawable(Color.WHITE)
            addView(TextView(ctx).apply { text = "Order total"; textSize = 20f })
            addView(EditText(ctx).apply { hint = "Card number"; setText("4242424242424242") })
            addView(EditText(ctx).apply { inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD; setText("hunter2") })
            addView(TextView(ctx).apply { text = "Loyalty 4417"; tag = "replayiq-mask" })
            addView(TextView(ctx).apply { text = "IBAN DE89"; ReplayIQ.mask(this) })
        }
        layout(root)
        val tree = walker().walk(root).root
        val json = tree.fullJson().toString()
        assertFalse(json.contains("4242424242424242"))
        assertFalse(json.contains("hunter2"))
        assertFalse(json.contains("4417"))
        assertFalse(json.contains("DE89"))
        assertTrue(json.contains("Order total"))
        assertEquals("#FFFFFFFF", tree.ownJson().getJSONObject("s").getString("bg"))
        val card = find(tree) { it.input?.ph == "Card number" }!!
        assertEquals(16, card.input!!.len)
        assertNotNull(find(tree) { it.input?.type == "password" })
        assertEquals(2, countKind(tree, "mask"))
    }

    private fun countKind(n: DomNode, k: String): Int = (if (n.k == k) 1 else 0) + n.c.sumOf { countKind(it, k) }

    @Test fun scrollViewChildrenStayInContentCoordinates() {
        val ctx: Application = ApplicationProvider.getApplicationContext()
        val content = LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            repeat(30) { i -> addView(TextView(ctx).apply { text = "Row $i"; height = 100 }) }
        }
        val scroll = ScrollView(ctx).apply { addView(content) }
        val root = FrameLayout(ctx).apply { addView(scroll) }
        layout(root)
        val w = walker()
        val before = find(w.walk(root).root) { it.k == "scroll" }!!
        scroll.scrollTo(0, 500)
        val after = find(w.walk(root).root) { it.k == "scroll" }!!
        assertEquals(0f, before.so!![1], 0.01f)
        assertTrue(after.so!![1] > 0f)
        // Rows don't move; only the scroll offset changes.
        val rowBefore = find(before) { it.tx?.v == "Row 10" }!!
        val rowAfter = find(after) { it.tx?.v == "Row 10" }!!
        assertEquals(rowBefore.y, rowAfter.y, 0.01f)
        assertEquals(before.id, after.id)
    }

    // ---------------------------------------------------------------- assets

    @Test fun assetIsHeadCheckedThenPostedOnceAndRemembered() {
        val server = MockWebServer().apply { start() }
        try {
            val queue = DiskQueue(tmp.newFolder("q2"))
            val store = AssetStore(tmp.newFolder("a2"), queue)
            val bytes = "png-bytes".toByteArray()
            val hash = AssetStore.sha256(bytes)
            assertTrue(store.register(hash, "image/png", bytes))
            assertFalse(store.register(hash, "image/png", bytes)) // already queued
            server.enqueue(MockResponse().setResponseCode(404))
            server.enqueue(MockResponse().setResponseCode(201))
            Uploader(queue, server.url("").toString().trimEnd('/'), "k", UrlConnectionSender, {}, assets = store).kick()
            val head = server.takeRequest(5, TimeUnit.SECONDS)!!
            assertEquals("HEAD", head.method)
            assertEquals("/api/v1/assets/$hash", head.path)
            val post = server.takeRequest(5, TimeUnit.SECONDS)!!
            assertEquals("POST", post.method)
            assertEquals(hash, post.getHeader("X-Asset-Hash"))
            assertEquals("image/png", post.getHeader("Content-Type"))
            assertEquals("png-bytes", post.body.readUtf8())
            val deadline = System.currentTimeMillis() + 5000
            while (queue.files().isNotEmpty() && System.currentTimeMillis() < deadline) Thread.sleep(20)
            Thread.sleep(50)
            // Known now (also after a restart): not uploaded again.
            assertFalse(AssetStore(tmp.root.resolve("a2"), queue).register(hash, "image/png", bytes))
        } finally {
            server.shutdown()
        }
    }

    @Test fun signalEventsKeepTheirCustomType() {
        val e = Events.signal("connectivity", 1L).put("network", "wifi")
        assertEquals(5, e.getInt("type"))
        val g = Events.gesture(1L, "swipe", "view:\"List\"", 10f, 20f, 0f, -120f)
        assertEquals(-120, g.getInt("dy"))
    }
}
