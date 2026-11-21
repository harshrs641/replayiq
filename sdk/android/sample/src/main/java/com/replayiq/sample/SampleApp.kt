package com.replayiq.sample

import android.app.Application
import com.replayiq.android.ReplayIQ
import com.replayiq.android.ReplayIQOkHttpInterceptor
import com.replayiq.android.ReplayIQOptions
import okhttp3.OkHttpClient

class SampleApp : Application() {
    override fun onCreate() {
        super.onCreate()
        ReplayIQ.start(
            this,
            BuildConfig.REPLAYIQ_KEY,
            BuildConfig.REPLAYIQ_ENDPOINT,
            ReplayIQOptions.Builder()
                .debug(true)
                .recordingMode(ReplayIQOptions.RecordingMode.valueOf(BuildConfig.REPLAYIQ_MODE))
                .build(),
        )
        ReplayIQ.identify("android-demo-user", mapOf("plan" to "pro"))
        // Measuring: adb shell am broadcast -a com.replayiq.sample.STATS [--ez reset true]
        val filter = android.content.IntentFilter("com.replayiq.sample.STATS")
        val receiver = object : android.content.BroadcastReceiver() {
            override fun onReceive(c: android.content.Context, i: android.content.Intent) {
                android.util.Log.i("ReplayIQStats", ReplayIQ.debugStats(reset = i.getBooleanExtra("reset", false)))
            }
        }
        if (android.os.Build.VERSION.SDK_INT >= 33) registerReceiver(receiver, filter, RECEIVER_EXPORTED) else registerReceiver(receiver, filter)
    }

    companion object {
        val http: OkHttpClient by lazy {
            OkHttpClient.Builder().addInterceptor(ReplayIQOkHttpInterceptor()).build()
        }
    }
}
