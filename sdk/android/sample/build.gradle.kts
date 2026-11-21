plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "com.replayiq.sample"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.replayiq.sample"
        minSdk = 24
        targetSdk = 35
        versionCode = 1
        versionName = "1.0"
        // The emulator reaches the host's ./dev.sh stack at 10.0.2.2. Override with -PreplayiqEndpoint=... -PreplayiqKey=...
        buildConfigField("String", "REPLAYIQ_ENDPOINT", "\"${project.findProperty("replayiqEndpoint") ?: "http://10.0.2.2:8080"}\"")
        buildConfigField("String", "REPLAYIQ_KEY", "\"${project.findProperty("replayiqKey") ?: "verify"}\"")
        // AUTO (default), NATIVE_DOM or SCREENSHOT: -PreplayiqMode=SCREENSHOT
        buildConfigField("String", "REPLAYIQ_MODE", "\"${project.findProperty("replayiqMode") ?: "AUTO"}\"")
    }

    buildTypes {
        // Non-debuggable build for measuring (debuggable builds run largely interpreted on the emulator).
        release {
            isMinifyEnabled = false
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    buildFeatures {
        buildConfig = true
        compose = true
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
}

dependencies {
    implementation(project(":replayiq"))
    implementation("androidx.fragment:fragment-ktx:1.8.5")
    implementation("androidx.recyclerview:recyclerview:1.3.2")
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation(platform("androidx.compose:compose-bom:2024.12.01"))
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-core")
    implementation("androidx.compose.ui:ui")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
}
