package com.replayiq.android.internal

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PoliciesTest {
    @Test fun keyframeOnFirstFrameSizeChangeAndEvery30s() {
        val p = KeyframePolicy()
        assertTrue(p.needsKeyframe(0, 400, 800))
        p.sent(0, 400, 800, keyframe = true)
        assertFalse(p.needsKeyframe(500, 400, 800))
        p.sent(500, 400, 800, keyframe = false)
        assertTrue("rotation", p.needsKeyframe(1000, 800, 400))
        assertFalse(p.needsKeyframe(29_999, 400, 800))
        assertTrue(p.needsKeyframe(30_000, 400, 800))
        p.reset()
        assertTrue(p.needsKeyframe(30_001, 400, 800))
    }

    @Test fun rageClickNeedsThreeNearbyTapsWithin700ms() {
        val r = RageClickDetector()
        assertFalse(r.onTap(0, 100f, 100f))
        assertFalse(r.onTap(200, 110f, 105f))
        assertTrue(r.onTap(400, 105f, 98f))
        assertFalse("same burst fires once", r.onTap(550, 100f, 100f))
    }

    @Test fun rageClickIgnoresFarOrSlowTaps() {
        val r = RageClickDetector()
        r.onTap(0, 100f, 100f)
        r.onTap(200, 300f, 300f) // far away
        assertFalse(r.onTap(400, 100f, 100f))
        val slow = RageClickDetector()
        slow.onTap(0, 10f, 10f); slow.onTap(400, 10f, 10f)
        assertFalse(slow.onTap(1200, 10f, 10f)) // first tap fell out of the window
    }

    @Test fun throttleAllowsOneCallPerInterval() {
        val t = Throttle(50)
        assertTrue(t.allow(0)); assertFalse(t.allow(49)); assertTrue(t.allow(50))
        t.reset(); assertTrue(t.allow(51))
    }

    @Test fun retryTableFollowsTheSpec() {
        assertEquals(Outcome.Done, RetryPolicy.decide(202, null, 0))
        assertEquals(Outcome.Done, RetryPolicy.decide(201, null, 0))
        assertEquals(Outcome.Drop, RetryPolicy.decide(400, null, 0))
        assertEquals(Outcome.Stop, RetryPolicy.decide(401, null, 0))
        assertEquals(Outcome.Stop, RetryPolicy.decide(403, null, 0))
        assertEquals(Outcome.Split, RetryPolicy.decide(413, null, 0))
        assertEquals(Outcome.Retry(7000), RetryPolicy.decide(429, 7, 0))
        assertEquals(Outcome.Retry(1000), RetryPolicy.decide(500, null, 0))
        assertEquals(Outcome.Retry(4000), RetryPolicy.decide(503, null, 2))
        assertEquals(Outcome.Retry(1000), RetryPolicy.decide(-1, null, 0))
        assertEquals(Outcome.Retry(60_000), RetryPolicy.decide(500, null, 12))
        assertEquals(listOf(1000L, 2000, 4000, 8000, 16000, 32000, 60000, 60000), (0..7).map(RetryPolicy::backoffMs))
    }
}
