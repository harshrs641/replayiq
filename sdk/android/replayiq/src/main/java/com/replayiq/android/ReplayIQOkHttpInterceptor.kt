package com.replayiq.android

import okhttp3.Interceptor
import okhttp3.Response
import java.io.IOException

/**
 * Records every request made through an OkHttp client as a `network` event (method, URL without
 * its query string, status, duration, error). Bodies and headers are never read.
 *
 * ```kotlin
 * val client = OkHttpClient.Builder().addInterceptor(ReplayIQOkHttpInterceptor()).build()
 * ```
 *
 * OkHttp is an optional dependency of the SDK: add `com.squareup.okhttp3:okhttp` (4.x or 5.x) yourself.
 */
class ReplayIQOkHttpInterceptor : Interceptor {
    @Throws(IOException::class)
    override fun intercept(chain: Interceptor.Chain): Response {
        val request = chain.request()
        val start = System.nanoTime()
        val response = try {
            chain.proceed(request)
        } catch (e: IOException) {
            ReplayIQ.recordNetwork(request.method, request.url.toString(), 0, elapsed(start), e.message ?: e.javaClass.simpleName)
            throw e
        }
        ReplayIQ.recordNetwork(request.method, request.url.toString(), response.code, elapsed(start), null)
        return response
    }

    private fun elapsed(startNs: Long) = (System.nanoTime() - startNs) / 1_000_000
}
