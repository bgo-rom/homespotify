package com.homespotify.audio.stretch;

import androidx.media3.exoplayer.audio.AudioSink;
import androidx.media3.exoplayer.audio.ForwardingAudioSink;

/** Audio-sink boundary that resets tempo before PCM from the next stream is accepted. */
final class HomeSpotifyAudioSink extends ForwardingAudioSink {
    private final HomeSpotifyAudioProcessorChain audioProcessorChain;
    private boolean hasOutputStreamOffset;
    private long outputStreamOffsetUs;

    HomeSpotifyAudioSink(
            AudioSink audioSink,
            HomeSpotifyAudioProcessorChain audioProcessorChain) {
        super(audioSink);
        this.audioProcessorChain = audioProcessorChain;
    }

    @Override
    public void setOutputStreamOffsetUs(long outputStreamOffsetUs) {
        if (hasOutputStreamOffset && this.outputStreamOffsetUs != outputStreamOffsetUs) {
            // MediaCodecAudioRenderer publishes the new stream offset before it sends
            // that stream's first decoded buffer to the sink. This is the synchronous
            // gapless boundary required to prevent track A's ratio/buffers reaching B.
            audioProcessorChain.onTrackTransition();
        }
        hasOutputStreamOffset = true;
        this.outputStreamOffsetUs = outputStreamOffsetUs;
        super.setOutputStreamOffsetUs(outputStreamOffsetUs);
    }

    @Override
    public void reset() {
        hasOutputStreamOffset = false;
        outputStreamOffsetUs = 0;
        super.reset();
    }

    @Override
    public void release() {
        try {
            super.release();
        } finally {
            audioProcessorChain.release();
        }
    }
}
