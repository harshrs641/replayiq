package com.replayiq.android;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNull;

import android.view.View;
import androidx.test.core.app.ApplicationProvider;
import java.util.Collections;
import okhttp3.OkHttpClient;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;

/** The public API must stay callable from Java (and so from a React Native bridge) without Kotlin types. */
@RunWith(RobolectricTestRunner.class)
public class JavaApiTest {
    @Test
    public void everyPublicCallCompilesAndIsSafeBeforeStart() {
        ReplayIQOptions options = new ReplayIQOptions.Builder()
                .sampleRate(0.5)
                .maskAllText(false)
                .imageScale(1.5f)
                .debug(true)
                .wrapper("react-native", "replayiq-react-native/1.0.0")
                .build();
        assertEquals("react-native", options.getPlatform());
        assertEquals(0.5, options.getSampleRate(), 0.0);

        // Before start(): no-ops, never throws.
        ReplayIQ.identify("u1");
        ReplayIQ.identify("u1", Collections.singletonMap("plan", "pro"));
        ReplayIQ.track("evt");
        ReplayIQ.track("evt", Collections.<String, Object>singletonMap("k", 1));
        ReplayIQ.screen("Home");
        ReplayIQ.log("hello");
        ReplayIQ.log("careful", "warn");
        ReplayIQ.logError(new RuntimeException("x"));
        ReplayIQ.recordNetwork("GET", "https://a.example/b", 200, 12L);
        ReplayIQ.recordNetwork("GET", "https://a.example/b", 0, 12L, "timeout");
        ReplayIQ.optOut();
        ReplayIQ.optIn();
        ReplayIQ.setSampleRate(1.0);
        ReplayIQ.flush();
        ReplayIQ.stop();
        ReplayIQ.reset();
        assertNull(ReplayIQ.getSessionId());
        assertEquals(false, ReplayIQ.isOptedOut());

        View v = new View(ApplicationProvider.getApplicationContext());
        ReplayIQ.mask(v);
        ReplayIQ.unmask(v);

        new OkHttpClient.Builder().addInterceptor(new ReplayIQOkHttpInterceptor()).build();
        ReplayIQ.getSdkVersion();
    }
}
