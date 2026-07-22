package com.ryanheise.just_audio;

import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import java.io.IOException;
import org.junit.Test;

public final class AudioPlayerDiagnosticsTest {
    @Test
    public void causeChainReachesDartWithoutBearerOrSensitiveUrl() {
        IOException source = new IOException(
                "Response code: 401 https://music.example.test/api/stream?signature=secret "
                        + "Bearer abc.def.ghi");
        String message = AudioPlayer.describeErrorChain("Source error", source);

        assertTrue(message.contains("Source error"));
        assertTrue(message.contains("IOException"));
        assertTrue(message.contains("Response code: 401"));
        assertTrue(message.contains("[url-redacted]"));
        assertTrue(message.contains("Bearer [redacted]"));
        assertFalse(message.contains("signature=secret"));
        assertFalse(message.contains("abc.def.ghi"));
    }

    @Test
    public void sanitizerBoundsUnexpectedNativeMessages() {
        String message = "x".repeat(2_000);
        String sanitized = AudioPlayer.sanitizeErrorMessage(message);
        assertTrue(sanitized.length() <= 1_603);
        assertTrue(sanitized.endsWith("..."));
    }
}
