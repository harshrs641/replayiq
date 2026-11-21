package com.replayiq.android.internal

import org.json.JSONObject

/** Builders for recording API v1 Custom events (type 5). */
internal object Events {
    private const val MAX_TEXT = 2_000
    private const val MAX_STACK = 16_000

    private fun custom(subtype: String, ts: Long) = JSONObject().put("type", 5).put("subtype", subtype).put("timestamp", ts)

    fun screen(ts: Long, widthDp: Int, heightDp: Int, jpegDataUrl: String, keyframe: Boolean): JSONObject =
        custom("screen", ts).put("width", widthDp).put("height", heightDp).put("image", jpegDataUrl).put("keyframe", keyframe)

    fun touch(ts: Long, xDp: Int, yDp: Int, phase: String): JSONObject =
        custom("touch", ts).put("x", xDp).put("y", yDp).put("phase", phase)

    fun navigate(ts: Long, url: String, message: String): JSONObject =
        custom("navigate", ts).put("url", url).put("message", message.take(MAX_TEXT))

    fun click(ts: Long, selector: String): JSONObject = custom("click", ts).put("selector", selector)

    fun rageClick(ts: Long, selector: String, xDp: Int, yDp: Int): JSONObject =
        custom("rage_click", ts).put("selector", selector).put("x", xDp).put("y", yDp)

    fun input(ts: Long, selector: String): JSONObject = custom("input", ts).put("selector", selector)

    fun console(ts: Long, level: String, message: String, stack: String?): JSONObject {
        val lvl = when (level.lowercase()) { "warn", "warning" -> "warn"; "error" -> "error"; else -> "log" }
        return custom("console", ts).put("level", lvl).put("message", message.take(MAX_TEXT))
            .apply { if (!stack.isNullOrEmpty()) put("stack", stack.take(MAX_STACK)) }
    }

    fun network(ts: Long, method: String, url: String, status: Int, durationMs: Long, error: String?): JSONObject =
        custom("network", ts).put("method", method.uppercase()).put("url", url.take(MAX_TEXT)).put("status", status)
            .put("duration", durationMs.coerceAtLeast(0))
            .apply { if (!error.isNullOrEmpty()) put("error", error.take(MAX_TEXT)) }

    fun runtimeError(ts: Long, message: String, stack: String?, filename: String?, line: Int, column: Int): JSONObject =
        custom("js_error", ts).put("message", message.take(MAX_TEXT)).apply {
            if (!stack.isNullOrEmpty()) put("stack", stack.take(MAX_STACK))
            if (!filename.isNullOrEmpty()) put("filename", filename)
            if (line > 0) put("lineno", line)
            if (column > 0) put("colno", column)
        }

    fun jsError(ts: Long, t: Throwable): JSONObject {
        val top = t.stackTrace.firstOrNull()
        val message = "${t.javaClass.name}: ${t.message ?: ""}".trimEnd(' ', ':')
        return custom("js_error", ts).put("message", message.take(MAX_TEXT))
            .put("filename", top?.let { it.fileName ?: it.className } ?: "")
            .put("lineno", (top?.lineNumber ?: 0).coerceAtLeast(0))
            .put("colno", 0)
            .put("stack", android.util.Log.getStackTraceString(t).ifEmpty { t.toString() }.take(MAX_STACK))
    }

    // ---- v1.1 mobile signals (recording API v1.1 §2)

    fun signal(subtype: String, ts: Long): JSONObject = custom(subtype, ts)

    fun gesture(ts: Long, kind: String, selector: String?, xDp: Float, yDp: Float, dxDp: Float = 0f, dyDp: Float = 0f, scale: Float = 0f): JSONObject =
        custom("gesture", ts).put("kind", kind).apply { selector?.let { put("selector", it) } }
            .put("x", DomNode.r1(xDp)).put("y", DomNode.r1(yDp))
            .apply { if (dxDp != 0f || dyDp != 0f) put("dx", DomNode.r1(dxDp)).put("dy", DomNode.r1(dyDp)) }
            .apply { if (scale > 0f) put("scale", DomNode.r2(scale)) }

    fun focus(ts: Long, focused: Boolean, selector: String): JSONObject = custom(if (focused) "focus" else "blur", ts).put("selector", selector)

    fun scroll(ts: Long, selector: String, xDp: Float, yDp: Float): JSONObject =
        custom("scroll", ts).put("selector", selector).put("x", DomNode.r1(xDp)).put("y", DomNode.r1(yDp))

    /** Strips the query/fragment (unless kept) so tokens in URLs aren't recorded. */
    fun sanitizeUrl(url: String, keepQuery: Boolean): String {
        if (keepQuery) return url
        val cut = url.indexOfAny(charArrayOf('?', '#'))
        return if (cut >= 0) url.substring(0, cut) else url
    }
}
