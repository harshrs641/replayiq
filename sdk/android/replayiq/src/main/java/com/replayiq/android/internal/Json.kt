package com.replayiq.android.internal

import org.json.JSONArray
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

internal object Json {
    private val iso = ThreadLocal.withInitial {
        SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US).apply { timeZone = TimeZone.getTimeZone("UTC") }
    }

    fun iso8601(ms: Long): String = iso.get()!!.format(Date(ms))

    /** Converts app-supplied values to JSON-safe ones (strings, numbers, booleans, maps, lists). */
    fun value(v: Any?): Any = when (v) {
        null -> JSONObject.NULL
        is String, is Boolean, is Int, is Long, is Double, is Float, is Short, is Byte -> v
        is Number -> v.toDouble()
        is Map<*, *> -> JSONObject().also { o -> v.forEach { (k, x) -> if (k != null) o.put(k.toString(), value(x)) } }
        is Iterable<*> -> JSONArray().also { a -> v.forEach { a.put(value(it)) } }
        is Array<*> -> JSONArray().also { a -> v.forEach { a.put(value(it)) } }
        else -> v.toString()
    }
}
