package com.replayiq.reactnative

import android.view.View
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod
import com.facebook.react.bridge.ReadableMap
import com.facebook.react.modules.network.OkHttpClientProvider
import com.replayiq.android.ReplayIQ
import com.replayiq.android.ReplayIQOkHttpInterceptor
import com.replayiq.android.ReplayIQOptions

/**
 * React Native bridge over the native ReplayIQ Android SDK. Screens, touches
 * and native crashes are recorded by the SDK; network through RN's OkHttp
 * client (interceptor installed here); JavaScript adds JS errors, console
 * lines and React Navigation screens through these methods.
 */
class ReplayIQRNModule(private val context: ReactApplicationContext) : ReactContextBaseJavaModule(context) {

    override fun getName() = "ReplayIQRN"

    init {
        // Before RN builds its first OkHttp client, so fetch/XHR are recorded.
        OkHttpClientProvider.setOkHttpClientFactory {
            OkHttpClientProvider.createClientBuilder().addInterceptor(ReplayIQOkHttpInterceptor()).build()
        }
    }

    @ReactMethod
    fun start(key: String, endpoint: String, options: ReadableMap) {
        val b = ReplayIQOptions.Builder()
            .wrapper("react-native", options.str("sdk") ?: "replayiq-react-native/unknown")
        options.dbl("sampleRate")?.let { b.sampleRate(it) }
        options.bool("maskAllTextInputs")?.let { b.maskAllInputs(it) }
        options.bool("maskAllText")?.let { b.maskAllText(it) }
        options.bool("debug")?.let { b.debug(it) }
        b.recordingMode(
            when (options.str("recordingMode")) {
                "nativeDom" -> ReplayIQOptions.RecordingMode.NATIVE_DOM
                "screenshot" -> ReplayIQOptions.RecordingMode.SCREENSHOT
                else -> ReplayIQOptions.RecordingMode.AUTO
            },
        )
        options.str("maskNativeID")?.let { maskId ->
            // <ReplayIQMask> renders a View with this nativeID.
            ReplayIQ.maskPredicate = ReplayIQ.MaskPredicate { v -> nativeId(v) == maskId }
        }
        ReplayIQ.start(context.currentActivity ?: context.applicationContext, key, endpoint, b.build())
    }

    @ReactMethod
    fun identify(userId: String, traits: ReadableMap) =
        ReplayIQ.identify(userId, traits.toHashMap().mapValues { it.value?.toString() ?: "" })

    @ReactMethod
    fun track(name: String, properties: ReadableMap) = ReplayIQ.track(name, properties.toHashMap())

    @ReactMethod
    fun screen(name: String) = ReplayIQ.screen(name)

    @ReactMethod
    fun log(message: String, level: String) = ReplayIQ.log(message, level)

    @ReactMethod
    fun recordError(message: String, stack: String, filename: String, line: Double, column: Double) =
        ReplayIQ.recordError(message, stack, filename, line.toInt(), column.toInt())

    @ReactMethod fun optOut() = ReplayIQ.optOut()
    @ReactMethod fun optIn() = ReplayIQ.optIn()
    @ReactMethod fun stop() = ReplayIQ.stop()
    @ReactMethod fun reset() = ReplayIQ.reset()
    @ReactMethod fun flush() = ReplayIQ.flush()

    @ReactMethod
    fun getSessionId(promise: Promise) = promise.resolve(ReplayIQ.sessionId)

    private fun nativeId(v: View): String? = v.getTag(com.facebook.react.R.id.view_tag_native_id) as? String

    private fun ReadableMap.str(k: String) = if (hasKey(k) && !isNull(k)) getString(k) else null
    private fun ReadableMap.dbl(k: String) = if (hasKey(k) && !isNull(k)) getDouble(k) else null
    private fun ReadableMap.bool(k: String) = if (hasKey(k) && !isNull(k)) getBoolean(k) else null
}
