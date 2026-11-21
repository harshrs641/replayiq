package com.replayiq.android.internal

import android.app.Application
import android.os.Looper
import androidx.test.core.app.ApplicationProvider
import com.replayiq.android.ReplayIQOptions
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import java.io.ByteArrayInputStream
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.zip.GZIPInputStream

@RunWith(RobolectricTestRunner::class)
class RecorderTest {
    @get:Rule val tmp = TemporaryFolder()

    private data class Req(val path: String, val body: JSONObject)

    private val app: Application = ApplicationProvider.getApplicationContext()
    private val sent = ArrayList<Req>()
    private var now = 1_800_000_000_000L
    private var status = 202
    private lateinit var queueDir: File
    private var savedHandler: Thread.UncaughtExceptionHandler? = null

    private val sender = HttpSender { url, _, gz ->
        val text = GZIPInputStream(ByteArrayInputStream(gz)).readBytes().toString(Charsets.UTF_8)
        synchronized(sent) { sent.add(Req(url.substringAfter("http://ingest.test"), JSONObject(text))) }
        status to null
    }

    @Before fun setUp() {
        queueDir = tmp.newFolder("queue")
        savedHandler = Thread.getDefaultUncaughtExceptionHandler()
    }

    @After fun tearDown() { Thread.setDefaultUncaughtExceptionHandler(savedHandler) }

    private fun recorder(options: ReplayIQOptions = ReplayIQOptions(), random: Double = 0.0) =
        Recorder(app, "verify", "http://ingest.test/", options, sender, { now }, { random }, queueDir).also {
            it.init(null)
            idle(it)
        }

    /** Waits for the worker thread, then runs the main looper. */
    private fun idle(r: Recorder) {
        repeat(2) {
            val latch = CountDownLatch(1)
            r.worker.post { latch.countDown() }
            assertTrue(latch.await(5, TimeUnit.SECONDS))
            shadowOf(Looper.getMainLooper()).idle()
        }
    }

    private fun flush(r: Recorder) { r.worker.post { r.flush() }; idle(r) }

    private fun awaitSent(n: Int): List<Req> {
        val deadline = System.currentTimeMillis() + 5_000
        while (System.currentTimeMillis() < deadline) {
            synchronized(sent) { if (sent.size >= n) return ArrayList(sent) }
            Thread.sleep(10)
        }
        synchronized(sent) { return ArrayList(sent) }
    }

    @Test fun firstFlushCreatesTheSessionThenSendsAMaskedBatch() {
        val r = recorder()
        val sid = r.recordingSessionId()
        assertNotNull(sid)
        r.identify("user_42", mapOf("plan" to "pro"))
        r.addEvent(Events.console(now, "log", "hello", null))
        r.track("checkout_started", mapOf("total" to 12.5))
        flush(r)
        val reqs = awaitSent(2)
        assertEquals("/api/v1/sessions", reqs[0].path)
        val create = reqs[0].body
        assertEquals(sid, create.getString("session_id"))
        assertEquals("user_42", create.getString("user_id"))
        assertEquals("android", create.getJSONObject("metadata").getString("platform"))
        assertEquals("pro", create.getJSONObject("metadata").getString("plan"))
        assertTrue(create.getString("url").startsWith("app://"))
        assertTrue(create.getString("sdk_version").startsWith("replayiq-android/"))

        assertEquals("/api/v1/events", reqs[1].path)
        val batch = reqs[1].body
        assertEquals("$sid-000001", batch.getString("batch_id"))
        assertTrue(batch.getBoolean("device_masked"))
        assertEquals("android", batch.getString("platform"))
        assertEquals("hello", batch.getJSONArray("events").getJSONObject(0).getString("message"))
        assertEquals("checkout_started", batch.getJSONArray("custom_events").getJSONObject(0).getString("name"))

        r.addEvent(Events.console(now, "log", "again", null))
        flush(r)
        assertEquals("$sid-000002", awaitSent(3)[2].body.getString("batch_id"))
    }

    @Test fun unsampledSessionsSendNothing() {
        val r = recorder(ReplayIQOptions.Builder().sampleRate(0.5).build(), random = 0.9)
        assertNull(r.recordingSessionId())
        r.addEvent(Events.console(now, "log", "x", null))
        flush(r)
        Thread.sleep(200)
        assertTrue(sent.isEmpty())
    }

    @Test fun optOutStopsRecordingAndForgetsQueuedData() {
        status = 503 // keep things queued
        val r = recorder()
        r.addEvent(Events.console(now, "log", "x", null))
        flush(r)
        r.optOut()
        idle(r)
        assertTrue(r.isOptedOut())
        assertNull(r.recordingSessionId())
        assertTrue(queueDir.listFiles()!!.none { it.name.endsWith(".req") })
        r.addEvent(Events.console(now, "log", "while opted out", null))
        r.optIn()
        idle(r)
        assertNotNull(r.recordingSessionId())
    }

    @Test fun crashIsPersistedThenChainsToThePreviousHandler() {
        status = 503 // nothing leaves the device, like a dying process
        var chained: Throwable? = null
        Thread.setDefaultUncaughtExceptionHandler { _, e -> chained = e }
        val r = recorder()
        val sid = r.recordingSessionId()
        r.addEvent(Events.console(now, "warn", "about to crash", null))
        val boom = IllegalStateException("boom")
        Thread.getDefaultUncaughtExceptionHandler()!!.uncaughtException(Thread.currentThread(), boom)
        assertEquals(boom, chained)

        val bodies = queueDir.listFiles()!!.filter { it.name.endsWith(".req") }.sortedBy { it.name }
            .map { it.readText().substringAfter('\n') }.map(::JSONObject)
        val batch = bodies.first { it.has("events") }
        assertEquals(sid, batch.getString("session_id"))
        val events = batch.getJSONArray("events")
        val last = events.getJSONObject(events.length() - 1)
        assertEquals("js_error", last.getString("subtype"))
        assertEquals("java.lang.IllegalStateException: boom", last.getString("message"))
        assertEquals("about to crash", events.getJSONObject(0).getString("message"))
    }

    @Test fun relaunchWithinTimeoutResumesTheSessionAfterItEndsIt() {
        val r1 = recorder()
        val first = r1.recordingSessionId()
        r1.addEvent(Events.console(now, "log", "x", null))
        flush(r1)
        awaitSent(2)

        now += 10 * 60_000 // relaunch 10 min later: same session
        val r2 = recorder()
        assertEquals(first, r2.recordingSessionId())

        now += 31 * 60_000 // relaunch 31 min after the last activity: ended, new session
        val r3 = recorder()
        val reqs = awaitSent(3)
        val end = reqs.first { it.path.endsWith("/end") }
        assertEquals("/api/v1/sessions/$first/end", end.path)
        assertTrue(end.body.getLong("duration_ms") >= 0)
        assertNotEquals(first, r3.recordingSessionId())
        assertFalse(r3.recordingSessionId().isNullOrEmpty())
    }
}
