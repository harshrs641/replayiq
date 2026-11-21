// Native side of replayiq_flutter: JPEG encoding and device info.
//
// The JPEG encoder is derived from mixpanel_flutter_session_replay 2.1.0
// (Copyright 2022 Mixpanel, Inc., Apache-2.0); see LICENSE and NOTICE.
// Changed: channel name, quality passed by Dart, Mixpanel super-property
// broadcasting removed, device info added.
package dev.replayiq.replayiq_flutter

import android.content.Context
import android.graphics.Bitmap
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import java.io.ByteArrayOutputStream
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

class ReplayIQFlutterPlugin : FlutterPlugin, MethodCallHandler {
    private lateinit var channel: MethodChannel
    private var executor: ExecutorService? = null
    private var context: Context? = null
    private val main = Handler(Looper.getMainLooper())

    // Reused across frames; only touched on the single encoder thread.
    private var bitmap: Bitmap? = null
    private var pixels: IntArray? = null
    private val out = ByteArrayOutputStream()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "dev.replayiq.flutter")
        channel.setMethodCallHandler(this)
        executor = Executors.newSingleThreadExecutor()
        context = binding.applicationContext
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        executor?.execute {
            bitmap?.recycle()
            bitmap = null
            pixels = null
        }
        executor?.shutdown()
        executor = null
        context = null
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "compressJpeg" -> compressJpeg(call, result)
            "deviceInfo" -> result.success(deviceInfo())
            "processStartMillis" -> result.success(
                System.currentTimeMillis() -
                    (android.os.SystemClock.elapsedRealtime() - android.os.Process.getStartElapsedRealtime())
            )
            "beginBackgroundTask", "endBackgroundTask" -> result.success(null)
            else -> result.notImplemented()
        }
    }

    private fun deviceInfo(): Map<String, String> {
        val info = mutableMapOf(
            "os" to "android",
            "os_version" to (Build.VERSION.RELEASE ?: ""),
            "device" to "${Build.MANUFACTURER} ${Build.MODEL}",
        )
        val ctx = context ?: return info
        try {
            info["bundle_id"] = ctx.packageName
            val pkg = ctx.packageManager.getPackageInfo(ctx.packageName, 0)
            val build = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                pkg.longVersionCode.toString()
            } else {
                @Suppress("DEPRECATION")
                pkg.versionCode.toString()
            }
            info["app_version"] = if (pkg.versionName != null) "${pkg.versionName} ($build)" else build
        } catch (_: Exception) {
            // Best effort.
        }
        return info
    }

    private fun compressJpeg(call: MethodCall, result: Result) {
        val rgba = call.argument<ByteArray>("rgba")
        val width = call.argument<Int>("width")
        val height = call.argument<Int>("height")
        val quality = call.argument<Int>("quality")
        if (rgba == null || width == null || height == null || quality == null) {
            result.error("INVALID_ARGS", "Missing arguments", null)
            return
        }
        val exec = executor
        if (exec == null || exec.isShutdown) {
            result.error("NOT_ATTACHED", "Plugin not attached", null)
            return
        }
        exec.execute {
            try {
                val count = width * height
                if (rgba.size != count * 4) {
                    main.post { result.error("INVALID_DATA", "Unexpected buffer size", null) }
                    return@execute
                }
                var px = pixels
                if (px == null || px.size != count) {
                    px = IntArray(count)
                    pixels = px
                }
                for (i in 0 until count) {
                    val o = i * 4
                    val r = rgba[o].toInt() and 0xFF
                    val g = rgba[o + 1].toInt() and 0xFF
                    val b = rgba[o + 2].toInt() and 0xFF
                    px[i] = (0xFF shl 24) or (r shl 16) or (g shl 8) or b
                }
                var bmp = bitmap
                if (bmp == null || bmp.isRecycled || bmp.width != width || bmp.height != height) {
                    bmp?.recycle()
                    bmp = Bitmap.createBitmap(width, height, Bitmap.Config.RGB_565)
                    bitmap = bmp
                }
                bmp!!.setPixels(px, 0, width, 0, 0, width, height)
                out.reset()
                bmp.compress(Bitmap.CompressFormat.JPEG, quality, out)
                val bytes = out.toByteArray()
                main.post { result.success(bytes) }
            } catch (e: Throwable) {
                main.post { result.error("ENCODE_FAILED", e.message, null) }
            }
        }
    }
}
