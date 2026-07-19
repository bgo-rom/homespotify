package com.homespotify.audio.stretch;

import android.content.Context;
import androidx.media3.common.PlaybackParameters;
import androidx.media3.common.audio.AudioProcessor;
import androidx.media3.common.audio.AudioProcessorChain;
import androidx.media3.exoplayer.audio.SilenceSkippingAudioProcessor;

/** Media3 chain with exactly one active tempo implementation at any time. */
public final class HomeSpotifyAudioProcessorChain implements AudioProcessorChain {
    private final HomeSpotifyStretchRuntime runtime;
    private final SilenceSkippingAudioProcessor silenceSkippingAudioProcessor;
    private final HomeSpotifyStretchAudioProcessor stretchAudioProcessor;
    private final AudioProcessor[] audioProcessors;

    public HomeSpotifyAudioProcessorChain(Context context) {
        runtime = new HomeSpotifyStretchRuntime(context);
        silenceSkippingAudioProcessor = new SilenceSkippingAudioProcessor();
        stretchAudioProcessor = new HomeSpotifyStretchAudioProcessor(runtime);
        // Keep Media3's established ordering: silence skipping before time-stretch.
        audioProcessors = new AudioProcessor[] {
            silenceSkippingAudioProcessor,
            stretchAudioProcessor
        };
    }

    @Override
    public AudioProcessor[] getAudioProcessors() {
        return audioProcessors;
    }

    @Override
    public PlaybackParameters applyPlaybackParameters(PlaybackParameters parameters) {
        return stretchAudioProcessor.setPlaybackParameters(parameters);
    }

    @Override
    public boolean applySkipSilenceEnabled(boolean skipSilenceEnabled) {
        silenceSkippingAudioProcessor.setEnabled(skipSilenceEnabled);
        return skipSilenceEnabled;
    }

    @Override
    public long getMediaDuration(long playoutDurationUs) {
        return stretchAudioProcessor.getMediaDuration(playoutDurationUs);
    }

    @Override
    public long getSkippedOutputFrameCount() {
        return silenceSkippingAudioProcessor.getSkippedFrames();
    }

    public void onExternalSpeedRequested() {
        stretchAudioProcessor.markControlTarget();
    }

    public void onSeek() {
        stretchAudioProcessor.requestSeekReset();
    }

    public void onTrackTransition() {
        logTrackSummary();
        stretchAudioProcessor.requestTrackReset();
    }

    public void forceFallback(String reason) {
        stretchAudioProcessor.forceFallback(reason);
    }

    public void release() {
        logTrackSummary();
        stretchAudioProcessor.reset();
    }

    // One summary line per track boundary; never per-buffer logging.
    private void logTrackSummary() {
        java.util.Map<String, Object> status = runtime.getStatusSnapshot();
        if (!(Boolean) status.get("active")
                && (Long) status.get("pcmFramesProcessed") == 0L) {
            return;
        }
        android.util.Log.i(
                "HomeSpotifyStretch",
                "track summary: mode=" + status.get("engineMode")
                        + " profile=" + status.get("profile")
                        + " ratio=" + status.get("appliedRatio")
                        + " frames=" + status.get("pcmFramesProcessed")
                        + " dspAvgUs=" + status.get("averageDspMicros")
                        + " dspMaxUs=" + status.get("maxDspMicros")
                        + " latencyMs=" + status.get("latencyMs")
                        + " underruns=" + status.get("underrunCount")
                        + " fallbacks=" + status.get("fallbackCount")
                        + " lastError=" + status.get("lastError"));
    }

    public HomeSpotifyStretchRuntime getRuntime() {
        return runtime;
    }
}
