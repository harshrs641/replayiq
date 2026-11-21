package com.replayiq.android.internal

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class EventsTest {
    @Test fun screenAndTouchFollowTheMobileFormat() {
        val s = Events.screen(10, 393, 852, "data:image/jpeg;base64,AAA", keyframe = true)
        assertEquals(5, s.getInt("type")); assertEquals("screen", s.getString("subtype"))
        assertEquals(393, s.getInt("width")); assertEquals(852, s.getInt("height")); assertTrue(s.getBoolean("keyframe"))
        val t = Events.touch(11, 196, 610, "down")
        assertEquals("touch", t.getString("subtype")); assertEquals(196, t.getInt("x")); assertEquals("down", t.getString("phase"))
    }

    @Test fun jsErrorCarriesMessageFrameAndStack() {
        val e = try { throw IllegalStateException("boom") } catch (x: IllegalStateException) { x }
        val ev = Events.jsError(5, e)
        assertEquals("js_error", ev.getString("subtype"))
        assertEquals("java.lang.IllegalStateException: boom", ev.getString("message"))
        assertEquals("EventsTest.kt", ev.getString("filename"))
        assertTrue(ev.getInt("lineno") > 0)
        assertTrue(ev.getString("stack").contains("boom"))
    }

    @Test fun consoleLevelsAreNormalised() {
        assertEquals("warn", Events.console(0, "WARNING", "m", null).getString("level"))
        assertEquals("error", Events.console(0, "error", "m", null).getString("level"))
        assertEquals("log", Events.console(0, "info", "m", null).getString("level"))
    }

    @Test fun networkUrlsLoseTheirQueryByDefault() {
        assertEquals("https://api.x.com/pay", Events.sanitizeUrl("https://api.x.com/pay?token=abc#f", keepQuery = false))
        assertEquals("https://api.x.com/pay?a=1", Events.sanitizeUrl("https://api.x.com/pay?a=1", keepQuery = true))
        val n = Events.network(0, "post", "https://a/b", 0, 12, "timeout")
        assertEquals("POST", n.getString("method")); assertEquals(0, n.getInt("status")); assertEquals("timeout", n.getString("error"))
    }
}
