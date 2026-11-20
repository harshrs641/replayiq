# ReplayIQ: keep the public API (Java / React Native callers).
-keep class com.replayiq.android.ReplayIQ { *; }
-keep class com.replayiq.android.ReplayIQOptions { *; }
-keep class com.replayiq.android.ReplayIQOptions$Builder { *; }
-keep class com.replayiq.android.ReplayIQOkHttpInterceptor { *; }
# Optional dependencies the SDK checks for at runtime.
-dontwarn androidx.compose.**
-dontwarn androidx.fragment.**
-dontwarn okhttp3.**
