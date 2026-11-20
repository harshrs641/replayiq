package com.replayiq.android.internal

import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okio.Buffer
import okio.GzipSource
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

@RunWith(RobolectricTestRunner::class)
class TransportTest {
    @get:Rule val tmp = TemporaryFolder()
    private lateinit var server: MockWebServer
    private lateinit var queue: DiskQueue

    @Before fun setUp() {
        server = MockWebServer().apply { start() }
        queue = DiskQueue(tmp.newFolder("q"))
    }

    @After fun tearDown() { server.shutdown() }

    private fun batch(id: String, n: Int) = JSONObject()
        .put("session_id", "s1").put("batch_id", id).put("device_masked", true)
        .put("events", JSONArray().apply { repeat(n) { put(JSONObject().put("type", 5).put("subtype", "console").put("timestamp", it)) } })
        .toString()

    private fun uploader(onStop: () -> Unit = {}) =
        Uploader(queue, server.url("").toString().trimEnd('/'), "key-123", UrlConnectionSender, onStop)

    private fun body(r: okhttp3.mockwebserver.RecordedRequest) =
        JSONObject(Buffer().apply { writeAll(GzipSource(r.body)) }.readUtf8())

    private fun awaitEmpty() {
        val deadline = System.currentTimeMillis() + 10_000
        while (queue.files().isNotEmpty() && System.currentTimeMillis() < deadline) Thread.sleep(20)
    }

    @Test fun sendsGzippedWithBearerKeyInOrder() {
        server.enqueue(MockResponse().setResponseCode(201))
        server.enqueue(MockResponse().setResponseCode(202))
        queue.add("/api/v1/sessions", JSONObject().put("session_id", "s1").toString())
        queue.add(DiskQueue.EVENTS_PATH, batch("s1-000001", 2))
        uploader().kick()
        val r1 = server.takeRequest(5, TimeUnit.SECONDS)!!
        val r2 = server.takeRequest(5, TimeUnit.SECONDS)!!
        assertEquals("/api/v1/sessions", r1.path)
        assertEquals("/api/v1/events", r2.path)
        assertEquals("Bearer key-123", r2.getHeader("Authorization"))
        assertEquals("gzip", r2.getHeader("Content-Encoding"))
        assertEquals("s1-000001", body(r2).getString("batch_id"))
        awaitEmpty()
        assertTrue(queue.files().isEmpty())
    }

    @Test fun retriesServerErrorsWithTheSameBatchId() {
        server.enqueue(MockResponse().setResponseCode(503))
        server.enqueue(MockResponse().setResponseCode(202))
        queue.add(DiskQueue.EVENTS_PATH, batch("s1-000007", 1))
        uploader().kick()
        val first = body(server.takeRequest(5, TimeUnit.SECONDS)!!)
        val retry = body(server.takeRequest(5, TimeUnit.SECONDS)!!) // after the 1 s backoff
        assertEquals("s1-000007", first.getString("batch_id"))
        assertEquals("s1-000007", retry.getString("batch_id"))
        awaitEmpty()
    }

    @Test fun dropsMalformedBatches() {
        server.enqueue(MockResponse().setResponseCode(400))
        server.enqueue(MockResponse().setResponseCode(202))
        queue.add(DiskQueue.EVENTS_PATH, batch("bad", 1))
        queue.add(DiskQueue.EVENTS_PATH, batch("good", 1))
        uploader().kick()
        assertEquals("bad", body(server.takeRequest(5, TimeUnit.SECONDS)!!).getString("batch_id"))
        assertEquals("good", body(server.takeRequest(5, TimeUnit.SECONDS)!!).getString("batch_id"))
        awaitEmpty()
    }

    @Test fun splitsTooLargeBatches() {
        server.enqueue(MockResponse().setResponseCode(413))
        server.enqueue(MockResponse().setResponseCode(202))
        server.enqueue(MockResponse().setResponseCode(202))
        queue.add(DiskQueue.EVENTS_PATH, batch("s1-000002", 4))
        uploader().kick()
        server.takeRequest(5, TimeUnit.SECONDS)
        val a = body(server.takeRequest(5, TimeUnit.SECONDS)!!)
        val b = body(server.takeRequest(5, TimeUnit.SECONDS)!!)
        assertEquals("s1-000002-a", a.getString("batch_id"))
        assertEquals("s1-000002-b", b.getString("batch_id"))
        assertEquals(2, a.getJSONArray("events").length())
        assertEquals(2, b.getJSONArray("events").length())
        awaitEmpty()
    }

    @Test fun stopsAndForgetsTheQueueOnRejectedKey() {
        server.enqueue(MockResponse().setResponseCode(401))
        queue.add(DiskQueue.EVENTS_PATH, batch("x1", 1))
        queue.add(DiskQueue.EVENTS_PATH, batch("x2", 1))
        val stopped = CountDownLatch(1)
        uploader { stopped.countDown() }.kick()
        assertTrue(stopped.await(5, TimeUnit.SECONDS))
        assertEquals(1, server.requestCount)
        assertTrue(queue.files().isEmpty())
    }

    @Test fun honoursRetryAfter() {
        server.enqueue(MockResponse().setResponseCode(429).setHeader("Retry-After", "1"))
        server.enqueue(MockResponse().setResponseCode(202))
        queue.add(DiskQueue.EVENTS_PATH, batch("r1", 1))
        val t0 = System.currentTimeMillis()
        uploader().kick()
        server.takeRequest(5, TimeUnit.SECONDS)
        server.takeRequest(5, TimeUnit.SECONDS)
        assertTrue(System.currentTimeMillis() - t0 >= 900)
    }

    @Test fun queueSurvivesRestartAndDropsOldestBatchesWhenFull() {
        val dir = tmp.newFolder("q2")
        val q = DiskQueue(dir)
        q.add("/api/v1/sessions", "{}")
        repeat(DiskQueue.MAX_EVENT_FILES + 5) { q.add(DiskQueue.EVENTS_PATH, batch("b$it", 1)) }
        val reopened = DiskQueue(dir)
        val items = reopened.files()
        assertEquals(DiskQueue.MAX_EVENT_FILES + 1, items.size)
        assertEquals("/api/v1/sessions", reopened.oldest()!!.path) // create kept, oldest batches dropped
    }
}
