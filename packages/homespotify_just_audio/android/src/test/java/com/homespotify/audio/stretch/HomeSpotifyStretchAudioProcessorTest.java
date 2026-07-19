package com.homespotify.audio.stretch;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import androidx.media3.common.C;
import androidx.media3.common.PlaybackParameters;
import androidx.media3.common.audio.AudioProcessor;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import org.junit.Test;

public final class HomeSpotifyStretchAudioProcessorTest {
    private static final int SAMPLE_RATE = 48_000;
    private static final int CHANNELS = 2;
    private static final long TEN_SECONDS_US = 10_000_000L;

    @Test
    public void media3FallbackCompletesAudioProcessorCycle() throws Exception {
        HomeSpotifyStretchAudioProcessor processor = createProcessor(false);
        processor.setPlaybackParameters(new PlaybackParameters(0.80f, 1.0f));
        processor.configure(pcm16Stereo());
        processor.flush();

        int outputBytes = queueSilenceAndDrain(processor, SAMPLE_RATE);
        processor.queueEndOfStream();
        outputBytes += drainEndOfStream(processor);

        assertTrue(outputBytes > 0);
        assertTrue(processor.isEnded());
        assertTrue(processor.usesMedia3FallbackForTesting());
        assertTrue(processor.isSonicActiveForTesting());
        assertFalse(processor.hasNativeHandleForTesting());

        // A flush starts a clean cycle without recreating the processor.
        processor.flush();
        assertFalse(processor.isEnded());
        assertTrue(queueSilenceAndDrain(processor, SAMPLE_RATE / 10) >= 0);
        processor.reset();
    }

    @Test
    public void convertsMediaAndPlayoutDurationsAtSupportedRatios() throws Exception {
        assertTimeline(0.70, 14_285_714L);
        assertTimeline(0.80, 12_500_000L);
        assertTimeline(1.20, 8_333_333L);
        assertTimeline(1.30, 7_692_307L);
    }

    @Test
    public void explicitMedia3ModeNeverCreatesNativeEngine() throws Exception {
        HomeSpotifyStretchAudioProcessor processor = createProcessor(false);
        processor.setPlaybackParameters(new PlaybackParameters(1.20f, 1.0f));
        processor.configure(pcm16Stereo());
        processor.flush();
        queueSilenceAndDrain(processor, SAMPLE_RATE / 10);

        assertTrue(processor.usesMedia3FallbackForTesting());
        assertTrue(processor.isSonicActiveForTesting());
        assertFalse(processor.hasNativeHandleForTesting());
        assertEquals(
                HomeSpotifyStretchRuntime.MODE_FALLBACK,
                processor.getRuntime().getStatusSnapshot().get("engineMode"));
        processor.reset();
    }

    @Test
    public void devMedia3OverrideActivatesAndReleasesFallbackAtFlushBoundaries()
            throws Exception {
        HomeSpotifyStretchAudioProcessor processor = createProcessor(true);
        HomeSpotifyStretchRuntime runtime = processor.getRuntime();
        processor.setPlaybackParameters(new PlaybackParameters(1.20f, 1.0f));
        processor.configure(pcm16Stereo());

        // Forced Media3 comparison: applied at the flush boundary only.
        runtime.setProfileOverride(HomeSpotifyStretchRuntime.OVERRIDE_MEDIA3);
        processor.flush();
        assertTrue(processor.usesMedia3FallbackForTesting());
        assertTrue(queueSilenceAndDrain(processor, SAMPLE_RATE) > 0);

        // Leaving the comparison unlatches at the next boundary; a JVM host
        // cannot load the .so, so the native attempt re-latches immediately —
        // proving both the unlatch and the genuine-failure re-latch paths.
        runtime.setProfileOverride(HomeSpotifyStretchRuntime.OVERRIDE_AUTO);
        processor.flush();
        assertFalse(runtime.getStatusSnapshot().get("lastError").toString().isEmpty());
        assertTrue(queueSilenceAndDrain(processor, SAMPLE_RATE / 10) >= 0);
        assertTrue(processor.usesMedia3FallbackForTesting());
        processor.reset();
    }

    @Test
    public void signalsmithModeKeepsSonicNeutralBeforeNativeInitialization() throws Exception {
        HomeSpotifyStretchAudioProcessor processor = createProcessor(true);
        processor.setPlaybackParameters(new PlaybackParameters(0.80f, 1.0f));
        processor.configure(pcm16Stereo());

        // A local JVM cannot load an Android .so. Before the first PCM/flush
        // boundary, verify only that the exclusive chain keeps Sonic neutral.
        assertFalse(processor.usesMedia3FallbackForTesting());
        assertFalse(processor.isSonicActiveForTesting());
        assertFalse(processor.hasNativeHandleForTesting());
        processor.reset();
    }

    private static HomeSpotifyStretchAudioProcessor createProcessor(boolean requestSignalsmith) {
        HomeSpotifyStretchRuntime runtime =
                new HomeSpotifyStretchRuntime(requestSignalsmith, true);
        return new HomeSpotifyStretchAudioProcessor(runtime);
    }

    private static AudioProcessor.AudioFormat pcm16Stereo() {
        return new AudioProcessor.AudioFormat(SAMPLE_RATE, CHANNELS, C.ENCODING_PCM_16BIT);
    }

    private static void assertTimeline(double ratio, long expectedPlayoutUs) throws Exception {
        HomeSpotifyStretchAudioProcessor processor = createProcessor(true);
        processor.setPlaybackParameters(new PlaybackParameters((float) ratio, 1.0f));
        processor.configure(pcm16Stereo());

        long playoutUs = processor.getDurationAfterProcessorApplied(TEN_SECONDS_US);
        assertWithin(expectedPlayoutUs, playoutUs, 2L);
        assertWithin(TEN_SECONDS_US, processor.getMediaDuration(playoutUs), 3L);
        processor.reset();
    }

    private static void assertWithin(long expected, long actual, long tolerance) {
        assertTrue(
                "expected " + expected + " +/- " + tolerance + " but was " + actual,
                Math.abs(expected - actual) <= tolerance);
    }

    private static int queueSilenceAndDrain(
            HomeSpotifyStretchAudioProcessor processor, int totalInputFrames) {
        int outputBytes = 0;
        int framesRemaining = totalInputFrames;
        while (framesRemaining > 0) {
            int frames = Math.min(1_024, framesRemaining);
            ByteBuffer input = ByteBuffer
                    .allocateDirect(frames * CHANNELS * 2)
                    .order(ByteOrder.nativeOrder());
            input.position(input.capacity());
            input.flip();
            processor.queueInput(input);
            assertFalse(input.hasRemaining());
            outputBytes += processor.getOutput().remaining();
            framesRemaining -= frames;
        }
        return outputBytes;
    }

    private static int drainEndOfStream(HomeSpotifyStretchAudioProcessor processor) {
        int outputBytes = 0;
        for (int attempt = 0; attempt < 16 && !processor.isEnded(); attempt++) {
            outputBytes += processor.getOutput().remaining();
        }
        return outputBytes;
    }
}
