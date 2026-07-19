package com.homespotify.audio.stretch;

import android.content.Context;
import androidx.media3.exoplayer.DefaultRenderersFactory;
import androidx.media3.exoplayer.audio.AudioSink;
import androidx.media3.exoplayer.audio.DefaultAudioSink;

/** Default Media3 renderers with HomeSpotify's exclusive audio-processor chain. */
public final class HomeSpotifyRenderersFactory extends DefaultRenderersFactory {
    private final HomeSpotifyAudioProcessorChain audioProcessorChain;

    public HomeSpotifyRenderersFactory(Context context) {
        super(context);
        audioProcessorChain = new HomeSpotifyAudioProcessorChain(context);
    }

    @Override
    protected AudioSink buildAudioSink(
            Context context,
            boolean enableFloatOutput,
            boolean enableAudioTrackPlaybackParams) {
        AudioSink defaultAudioSink = new DefaultAudioSink.Builder(context)
                .setAudioProcessorChain(audioProcessorChain)
                // The processor contract is PCM16 at the Media3 boundary and float32 only inside
                // JNI. AudioTrack PlaybackParams must remain disabled or Sonic/platform speed
                // would run a second time.
                .setEnableFloatOutput(false)
                .setEnableAudioTrackPlaybackParams(false)
                .build();
        return new HomeSpotifyAudioSink(defaultAudioSink, audioProcessorChain);
    }

    public HomeSpotifyAudioProcessorChain getAudioProcessorChain() {
        return audioProcessorChain;
    }
}
