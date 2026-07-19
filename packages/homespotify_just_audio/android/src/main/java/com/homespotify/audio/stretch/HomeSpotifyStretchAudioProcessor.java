package com.homespotify.audio.stretch;

import androidx.media3.common.C;
import androidx.media3.common.PlaybackParameters;
import androidx.media3.common.audio.AudioProcessor;
import androidx.media3.common.audio.SonicAudioProcessor;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.FloatBuffer;
import java.nio.ShortBuffer;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.AtomicReference;

/**
 * Media3 PCM16 processor backed by Signalsmith Stretch with a latched Sonic fallback.
 *
 * <p>The two tempo paths are mutually exclusive. The fallback Sonic processor lives inside this
 * processor so a native failure can consume the still-uncommitted input block without requiring a
 * second Media3 processor-chain reconfiguration.
 */
public final class HomeSpotifyStretchAudioProcessor implements AudioProcessor {
    public static final double MIN_RATIO = 0.70;
    public static final double MAX_RATIO = 1.30;
    public static final double RATIO_TOLERANCE = 0.0001;

    private static final int PCM16_BYTES_PER_SAMPLE = 2;
    private static final int FLOAT_BYTES_PER_SAMPLE = 4;
    private static final int INITIAL_PCM_CAPACITY_BYTES = 64 * 1024;
    private static final int NATIVE_OUTPUT_MARGIN_FRAMES = 4096;
    private static final int FLUSH_OUTPUT_MARGIN_FRAMES = 16 * 1024;
    private static final int METRICS_SNAPSHOT_INTERVAL = 128;

    private final HomeSpotifyStretchRuntime runtime;
    private final SonicAudioProcessor sonicFallback = new SonicAudioProcessor();
    private final AtomicLong nativeHandle = new AtomicLong();
    private final AtomicReference<String> forcedFallbackReason = new AtomicReference<>();

    private AudioFormat pendingInputFormat = AudioFormat.NOT_SET;
    private AudioFormat inputFormat = AudioFormat.NOT_SET;
    private ByteBuffer outputBuffer = EMPTY_BUFFER;
    private ByteBuffer pcmStagingBuffer = EMPTY_BUFFER;
    private ByteBuffer pcmOutputBuffer = EMPTY_BUFFER;
    private ByteBuffer nativeInputBuffer = EMPTY_BUFFER;
    private ByteBuffer nativeOutputBuffer = EMPTY_BUFFER;
    private byte[] pendingPcmBytes = new byte[0];
    private int pendingPcmByteCount;
    private volatile double requestedRatio = 1.0;
    private int latencyFrames;
    private boolean inputEnded;
    private boolean nativeDrained;
    private boolean nativeWasFlushed;
    private boolean fallbackMode;
    private boolean formatChanged;
    private volatile boolean trackResetRequested;
    private int nativeProcessCalls;

    public HomeSpotifyStretchAudioProcessor(HomeSpotifyStretchRuntime runtime) {
        this.runtime = runtime;
    }

    public PlaybackParameters setPlaybackParameters(PlaybackParameters parameters) {
        double ratio = parameters.speed;
        validateRatio(ratio);
        double previousRatio = requestedRatio;
        requestedRatio = ratio;
        runtime.setRequestedRatio(ratio);

        if (fallbackMode || runtime.isFallbackLatched()) {
            sonicFallback.setSpeed((float) ratio);
            sonicFallback.setPitch(1.0f);
        } else {
            long handle = nativeHandle.get();
            if (handle != 0 && !nativeWasFlushed) {
                try {
                    NativeStretchBridge.setRatio(
                            handle, ratio, transitionFrames(previousRatio, ratio));
                    double nativeAppliedRatio = NativeStretchBridge.getApplied(handle);
                    runtime.recordNativeActive(
                            ratio,
                            nativeAppliedRatio,
                            latencyFrames,
                            inputFormat.sampleRate,
                            inputFormat.channelCount);
                } catch (RuntimeException | LinkageError error) {
                    activateFallback(errorMessage(error));
                }
            }
        }
        return new PlaybackParameters((float) ratio, 1.0f);
    }

    public void markControlTarget() {
        runtime.markControlTarget();
    }

    public void requestSeekReset() {
        runtime.requestSeekReset();
    }

    public void requestTrackReset() {
        trackResetRequested = true;
        requestedRatio = 1.0;
        runtime.setRequestedRatio(1.0);
        runtime.recordUnitSpeed();
    }

    public void forceFallback(String reason) {
        // Player.Listener runs on the application looper. Never dispose a native pointer there
        // while the playback thread may still be inside processDirect.
        forcedFallbackReason.set(reason);
        runtime.recordError(reason);
    }

    public HomeSpotifyStretchRuntime getRuntime() {
        return runtime;
    }

    boolean usesMedia3FallbackForTesting() {
        return fallbackMode || runtime.isFallbackLatched();
    }

    boolean hasNativeHandleForTesting() {
        return nativeHandle.get() != 0;
    }

    boolean isSonicActiveForTesting() {
        return sonicFallback.isActive();
    }

    @Override
    public AudioFormat configure(AudioFormat inputAudioFormat)
            throws UnhandledAudioFormatException {
        if (inputAudioFormat.encoding != C.ENCODING_PCM_16BIT) {
            throw new UnhandledAudioFormatException(inputAudioFormat);
        }

        formatChanged = !sameFormat(pendingInputFormat, inputAudioFormat);
        pendingInputFormat = inputAudioFormat;
        sonicFallback.configure(inputAudioFormat);
        pendingPcmBytes = new byte[Math.max(2, inputAudioFormat.bytesPerFrame * 2)];
        if (Math.abs(requestedRatio - 1.0) >= RATIO_TOLERANCE) {
            preallocateRealtimeBuffers();
        }

        if (inputAudioFormat.channelCount != 1 && inputAudioFormat.channelCount != 2) {
            activateFallback("UNSUPPORTED_FORMAT: HomeSpotify Stretch supports mono and stereo");
        }
        return inputAudioFormat;
    }

    @Override
    public boolean isActive() {
        return pendingInputFormat != AudioFormat.NOT_SET
                && Math.abs(requestedRatio - 1.0) >= RATIO_TOLERANCE;
    }

    @Override
    public void queueInput(ByteBuffer inputBuffer) {
        if (!inputBuffer.hasRemaining() || outputBuffer.hasRemaining()) {
            return;
        }
        applyForcedFallbackIfNeeded();
        if (runtime.consumeOverloadFallbackRequest()) {
            // Switching Signalsmith profiles resets its STFT and cannot be made transparent in
            // this Media3 callback. Prefer one latched Sonic fallback over repeated quality-mode
            // oscillation or continued deadline misses.
            activateFallback("DSP_OVERLOAD: six consecutive real-time deadlines were missed");
        }
        applyPendingResetIfNeeded();

        int completeFrames = stageCompleteFrames(inputBuffer);
        if (completeFrames == 0) {
            return;
        }

        if (fallbackMode || runtime.isFallbackLatched()) {
            queueStagedInputToFallback();
            return;
        }

        try {
            ensureNativeInitialized();
            convertPcm16ToFloat(completeFrames);
            int outputCapacityFrames = expectedOutputCapacityFrames(completeFrames);
            ensureNativeOutputCapacity(outputCapacityFrames);
            nativeOutputBuffer.clear();
            nativeOutputBuffer.limit(checkedByteCount(
                    outputCapacityFrames,
                    inputFormat.channelCount,
                    FLOAT_BYTES_PER_SAMPLE));

            long startedNanos = System.nanoTime();
            int outputFrames = NativeStretchBridge.processDirect(
                    nativeHandle.get(),
                    nativeInputBuffer,
                    completeFrames,
                    nativeOutputBuffer,
                    outputCapacityFrames);
            long dspMicros = Math.max(0L, (System.nanoTime() - startedNanos) / 1000L);
            validateOutputFrameCount(outputFrames, outputCapacityFrames);

            runtime.recordDsp(
                    completeFrames,
                    dspMicros,
                    inputFormat.sampleRate,
                    requestedRatio);
            double nativeAppliedRatio = NativeStretchBridge.getApplied(nativeHandle.get());
            latencyFrames = Math.max(0, NativeStretchBridge.getLatency(nativeHandle.get()));
            runtime.recordNativeActive(
                    requestedRatio,
                    nativeAppliedRatio,
                    latencyFrames,
                    inputFormat.sampleRate,
                    inputFormat.channelCount);
            if (++nativeProcessCalls % METRICS_SNAPSHOT_INTERVAL == 0) {
                runtime.updateNativeSnapshot(NativeStretchBridge.getMetrics(nativeHandle.get()));
            }
            outputBuffer = convertFloatToPcm16(outputFrames);
        } catch (NativeFallbackActivatedException error) {
            pcmStagingBuffer.position(0);
            queueStagedInputToFallback();
        } catch (RuntimeException | LinkageError error) {
            activateFallback(errorMessage(error));
            pcmStagingBuffer.position(0);
            queueStagedInputToFallback();
        }
    }

    @Override
    public void queueEndOfStream() {
        inputEnded = true;
        if (pendingPcmByteCount != 0) {
            runtime.recordError(
                    "INCOMPLETE_PCM_FRAME: trailing PCM bytes were discarded at end of stream");
        }
        pendingPcmByteCount = 0;
        if (fallbackMode || runtime.isFallbackLatched()) {
            sonicFallback.queueEndOfStream();
        } else {
            nativeDrained = false;
        }
    }

    @Override
    public ByteBuffer getOutput() {
        if (outputBuffer.hasRemaining()) {
            ByteBuffer output = outputBuffer;
            outputBuffer = EMPTY_BUFFER;
            return output;
        }
        if (fallbackMode || runtime.isFallbackLatched()) {
            return sonicFallback.getOutput();
        }
        if (inputEnded && !nativeDrained) {
            return flushNativeOutput();
        }
        return EMPTY_BUFFER;
    }

    @Override
    public boolean isEnded() {
        if (fallbackMode || runtime.isFallbackLatched()) {
            return inputEnded && sonicFallback.isEnded() && !outputBuffer.hasRemaining();
        }
        return inputEnded && nativeDrained && !outputBuffer.hasRemaining();
    }

    @Override
    public void flush() {
        applyForcedFallbackIfNeeded();
        boolean fallbackClearRequested = runtime.consumeFallbackClearRequest();
        if (fallbackClearRequested && fallbackMode && runtime.unlatchFallback()) {
            // Dev/A-B: leaving the forced Media3 comparison at a PCM boundary.
            // Any real native failure immediately re-latches the fallback.
            fallbackMode = false;
        }
        if (runtime.getProfileOverride() == HomeSpotifyStretchRuntime.OVERRIDE_MEDIA3
                && !fallbackMode
                && !runtime.isFallbackLatched()) {
            activateFallback("DEV_OVERRIDE: Media3 fallback forced for A/B comparison");
        }
        boolean trackReset = trackResetRequested;
        trackResetRequested = false;
        forcedFallbackReason.set(null);
        runtime.consumeSeekResetRequest();

        inputFormat = pendingInputFormat;
        outputBuffer = EMPTY_BUFFER;
        pendingPcmByteCount = 0;
        inputEnded = false;
        nativeDrained = false;
        nativeProcessCalls = 0;

        // Keep Sonic genuinely neutral while Signalsmith owns tempo. It is configured in
        // advance, but receives neither the requested ratio nor PCM unless fallback is latched.
        sonicFallback.setSpeed(
                fallbackMode || runtime.isFallbackLatched()
                        ? (float) requestedRatio
                        : 1.0f);
        sonicFallback.setPitch(1.0f);
        sonicFallback.flush();

        if (trackReset) {
            requestedRatio = 1.0;
            runtime.setRequestedRatio(1.0);
        }
        if (!isActive()) {
            disposeNative();
            latencyFrames = 0;
            runtime.recordUnitSpeed();
            formatChanged = false;
            return;
        }

        preallocateRealtimeBuffers();
        if (fallbackMode || runtime.isFallbackLatched()) {
            runtime.recordFallbackActive(null);
            formatChanged = false;
            return;
        }

        try {
            ensureNativeInitialized();
            long handle = nativeHandle.get();
            // AudioProcessor.flush() is a hard PCM boundary in Media3. Always purge
            // Signalsmith here so decoded samples buffered before a seek, stop, or
            // renderer reset can never leak into the resumed stream.
            NativeStretchBridge.reset(handle);
            nativeWasFlushed = false;
            applyNativeProfileOverride(handle);
            NativeStretchBridge.setRatio(
                    handle,
                    requestedRatio,
                    0);
            double nativeAppliedRatio = NativeStretchBridge.getApplied(handle);
            latencyFrames = Math.max(0, NativeStretchBridge.getLatency(handle));
            runtime.recordNativeActive(
                    requestedRatio,
                    nativeAppliedRatio,
                    latencyFrames,
                    inputFormat.sampleRate,
                    inputFormat.channelCount);
        } catch (NativeFallbackActivatedException error) {
            sonicFallback.setSpeed((float) requestedRatio);
            sonicFallback.setPitch(1.0f);
            sonicFallback.flush();
        } catch (RuntimeException | LinkageError error) {
            activateFallback(errorMessage(error));
            sonicFallback.setSpeed((float) requestedRatio);
            sonicFallback.setPitch(1.0f);
            sonicFallback.flush();
        } finally {
            formatChanged = false;
        }
    }

    @Override
    public void reset() {
        disposeNative();
        sonicFallback.reset();
        pendingInputFormat = AudioFormat.NOT_SET;
        inputFormat = AudioFormat.NOT_SET;
        outputBuffer = EMPTY_BUFFER;
        pcmStagingBuffer = EMPTY_BUFFER;
        pcmOutputBuffer = EMPTY_BUFFER;
        nativeInputBuffer = EMPTY_BUFFER;
        nativeOutputBuffer = EMPTY_BUFFER;
        pendingPcmBytes = new byte[0];
        pendingPcmByteCount = 0;
        requestedRatio = 1.0;
        latencyFrames = 0;
        inputEnded = false;
        nativeDrained = false;
        nativeWasFlushed = false;
        formatChanged = false;
        trackResetRequested = false;
        forcedFallbackReason.set(null);
        runtime.recordUnitSpeed();
        runtime.clearControlTarget();
    }

    @Override
    public long getDurationAfterProcessorApplied(long mediaDurationUs) {
        if (!isActive()) {
            return mediaDurationUs;
        }
        if (fallbackMode || runtime.isFallbackLatched()) {
            return sonicFallback.getDurationAfterProcessorApplied(mediaDurationUs);
        }
        // Native pre-roll consumes input before producing output and returns its tail at EOS. Raw
        // input/output counters therefore cannot represent a checkpoint duration without explicit
        // native "media frames represented" counters. The accepted tempo is the stable Media3
        // mapping and avoids a startup jump or progressive drift.
        return (long) (mediaDurationUs / Math.max(MIN_RATIO, requestedRatio));
    }

    public long getMediaDuration(long playoutDurationUs) {
        if (!isActive()) {
            return playoutDurationUs;
        }
        if (fallbackMode || runtime.isFallbackLatched()) {
            return sonicFallback.getMediaDuration(playoutDurationUs);
        }
        return (long) (playoutDurationUs * requestedRatio);
    }

    private int stageCompleteFrames(ByteBuffer inputBuffer) {
        int bytesPerFrame = inputFormat.bytesPerFrame;
        int incomingBytes = inputBuffer.remaining();
        int totalBytes = pendingPcmByteCount + incomingBytes;
        int minimumFrames = fallbackMode || runtime.isFallbackLatched() ? 1 : 2;
        int completeFrames = totalBytes / bytesPerFrame;

        ensurePcmStagingCapacity(totalBytes);
        pcmStagingBuffer.clear();
        if (pendingPcmByteCount > 0) {
            pcmStagingBuffer.put(pendingPcmBytes, 0, pendingPcmByteCount);
        }
        pcmStagingBuffer.put(inputBuffer);
        pcmStagingBuffer.flip();

        if (completeFrames < minimumFrames) {
            pendingPcmByteCount = totalBytes;
            pcmStagingBuffer.get(pendingPcmBytes, 0, pendingPcmByteCount);
            pcmStagingBuffer.limit(0);
            pcmStagingBuffer.position(0);
            return 0;
        }

        int completeBytes = completeFrames * bytesPerFrame;
        pendingPcmByteCount = totalBytes - completeBytes;
        if (pendingPcmByteCount > 0) {
            for (int index = 0; index < pendingPcmByteCount; index++) {
                pendingPcmBytes[index] = pcmStagingBuffer.get(completeBytes + index);
            }
        }
        pcmStagingBuffer.limit(completeBytes);
        pcmStagingBuffer.position(0);
        return completeFrames;
    }

    private void queueStagedInputToFallback() {
        sonicFallback.queueInput(pcmStagingBuffer);
        outputBuffer = sonicFallback.getOutput();
    }

    private void convertPcm16ToFloat(int inputFrames) {
        int samples = checkedProduct(inputFrames, inputFormat.channelCount);
        int floatBytes = checkedProduct(samples, FLOAT_BYTES_PER_SAMPLE);
        ensureNativeInputCapacity(floatBytes);
        nativeInputBuffer.clear();
        nativeInputBuffer.limit(floatBytes);
        ShortBuffer shorts = pcmStagingBuffer
                .duplicate()
                .order(ByteOrder.nativeOrder())
                .asShortBuffer();
        FloatBuffer floats = nativeInputBuffer.asFloatBuffer();
        while (shorts.hasRemaining()) {
            floats.put(shorts.get() / 32768.0f);
        }
        nativeInputBuffer.position(0);
    }

    private ByteBuffer convertFloatToPcm16(int outputFrames) {
        if (outputFrames == 0) {
            return EMPTY_BUFFER;
        }
        int samples = checkedProduct(outputFrames, inputFormat.channelCount);
        int outputBytes = checkedProduct(samples, PCM16_BYTES_PER_SAMPLE);
        ensurePcmOutputCapacity(outputBytes);
        pcmOutputBuffer.clear();
        pcmOutputBuffer.limit(outputBytes);
        FloatBuffer floats = nativeOutputBuffer
                .duplicate()
                .order(ByteOrder.nativeOrder())
                .asFloatBuffer();
        floats.limit(samples);
        while (floats.hasRemaining()) {
            float sample = floats.get();
            if (Float.isNaN(sample) || Float.isInfinite(sample)) {
                throw new IllegalStateException("NATIVE_PROCESSING_FAILED: non-finite PCM output");
            }
            int pcmSample;
            if (sample >= 1.0f) {
                pcmSample = Short.MAX_VALUE;
            } else if (sample <= -1.0f) {
                pcmSample = Short.MIN_VALUE;
            } else {
                pcmSample = Math.round(sample * Short.MAX_VALUE);
            }
            pcmOutputBuffer.putShort((short) pcmSample);
        }
        pcmOutputBuffer.flip();
        return pcmOutputBuffer;
    }

    private ByteBuffer flushNativeOutput() {
        long handle = nativeHandle.get();
        if (handle == 0) {
            nativeDrained = true;
            return EMPTY_BUFFER;
        }
        try {
            long latencyCapacity = (long) latencyFrames * 4L + 1024L;
            if (latencyCapacity > Integer.MAX_VALUE) {
                throw new IllegalArgumentException("BUFFER_TOO_SMALL: flush capacity overflow");
            }
            int outputCapacityFrames = Math.max(
                    FLUSH_OUTPUT_MARGIN_FRAMES, (int) latencyCapacity);
            ensureNativeOutputCapacity(outputCapacityFrames);
            nativeOutputBuffer.clear();
            nativeOutputBuffer.limit(checkedByteCount(
                    outputCapacityFrames,
                    inputFormat.channelCount,
                    FLOAT_BYTES_PER_SAMPLE));
            long startedNanos = System.nanoTime();
            int outputFrames = NativeStretchBridge.flushDirect(
                    handle, nativeOutputBuffer, outputCapacityFrames);
            long dspMicros = Math.max(0L, (System.nanoTime() - startedNanos) / 1000L);
            validateOutputFrameCount(outputFrames, outputCapacityFrames);
            runtime.recordDsp(0, dspMicros, inputFormat.sampleRate, requestedRatio);
            if (outputFrames == 0) {
                nativeDrained = true;
                nativeWasFlushed = true;
                runtime.updateNativeSnapshot(NativeStretchBridge.getMetrics(handle));
                return EMPTY_BUFFER;
            }
            return convertFloatToPcm16(outputFrames);
        } catch (RuntimeException | LinkageError error) {
            activateFallback(errorMessage(error));
            sonicFallback.queueEndOfStream();
            return sonicFallback.getOutput();
        }
    }

    private void applyPendingResetIfNeeded() {
        boolean trackReset = trackResetRequested;
        boolean seekReset = runtime.consumeSeekResetRequest();
        if (!trackReset && !seekReset) {
            return;
        }
        trackResetRequested = false;
        if (trackReset) {
            requestedRatio = 1.0;
            runtime.setRequestedRatio(1.0);
        }
        pendingPcmByteCount = 0;
        outputBuffer = EMPTY_BUFFER;
        inputEnded = false;
        nativeDrained = false;
        if (fallbackMode || runtime.isFallbackLatched()) {
            sonicFallback.setSpeed((float) requestedRatio);
            sonicFallback.setPitch(1.0f);
            sonicFallback.flush();
            return;
        }
        long handle = nativeHandle.get();
        if (handle != 0) {
            try {
                NativeStretchBridge.reset(handle);
                applyNativeProfileOverride(handle);
                NativeStretchBridge.setRatio(handle, requestedRatio, 0);
                nativeWasFlushed = false;
            } catch (RuntimeException | LinkageError error) {
                activateFallback(errorMessage(error));
            }
        }
    }

    /** The native side only knows profile ordinals; MEDIA3 stays a Java concern. */
    private void applyNativeProfileOverride(long handle) {
        int override = runtime.getProfileOverride();
        NativeStretchBridge.setProfileOverride(
                handle,
                override >= 0 && override <= 2
                        ? override
                        : HomeSpotifyStretchRuntime.OVERRIDE_AUTO);
    }

    private void applyForcedFallbackIfNeeded() {
        String reason = forcedFallbackReason.getAndSet(null);
        if (reason != null) {
            activateFallback(reason);
        }
    }

    private void ensureNativeInitialized() {
        if (nativeHandle.get() != 0 && !formatChanged) {
            return;
        }
        if (!runtime.canAttemptNative()) {
            activateFallback("MEDIA3_FALLBACK: Signalsmith is disabled or unsupported");
            throw new NativeFallbackActivatedException();
        }
        if (!NativeStretchBridge.ensureLoaded()) {
            activateFallback(NativeStretchBridge.getLoadError());
            throw new NativeFallbackActivatedException();
        }

        disposeNative();
        long handle = 0;
        try {
            handle = NativeStretchBridge.create();
            if (handle == 0) {
                throw new IllegalStateException("NATIVE_INITIALIZATION_FAILED: native handle is null");
            }
            NativeStretchBridge.initialize(
                    handle, inputFormat.sampleRate, inputFormat.channelCount);
            applyNativeProfileOverride(handle);
            NativeStretchBridge.setRatio(handle, requestedRatio, 0);
            nativeHandle.set(handle);
            handle = 0;
            nativeWasFlushed = false;
            double nativeAppliedRatio = NativeStretchBridge.getApplied(nativeHandle.get());
            latencyFrames = Math.max(0, NativeStretchBridge.getLatency(nativeHandle.get()));
            runtime.recordNativeActive(
                    requestedRatio,
                    nativeAppliedRatio,
                    latencyFrames,
                    inputFormat.sampleRate,
                    inputFormat.channelCount);
        } finally {
            if (handle != 0) {
                NativeStretchBridge.dispose(handle);
            }
        }
    }

    private void activateFallback(String reason) {
        if (!fallbackMode) {
            fallbackMode = true;
            disposeNative();
        }
        runtime.recordFallbackActive(reason);
        sonicFallback.setSpeed((float) requestedRatio);
        sonicFallback.setPitch(1.0f);
        if (inputFormat != AudioFormat.NOT_SET) {
            // setSpeed applies to a newly created Sonic instance on flush. At this point no Sonic
            // PCM has been accepted in native mode, so this cannot discard audible fallback data.
            sonicFallback.flush();
        }
    }

    private void disposeNative() {
        long handle = nativeHandle.getAndSet(0);
        if (handle != 0) {
            try {
                NativeStretchBridge.dispose(handle);
            } catch (RuntimeException | LinkageError ignored) {
                // Disposal is idempotent and no JNI exception may escape Media3 teardown.
            }
        }
        nativeWasFlushed = false;
    }

    private int expectedOutputCapacityFrames(int inputFrames) {
        long stretchedFrames = (long) Math.ceil(inputFrames / MIN_RATIO);
        long margin = Math.max(NATIVE_OUTPUT_MARGIN_FRAMES, (long) latencyFrames * 2L);
        long capacity = stretchedFrames + margin;
        if (capacity < stretchedFrames) {
            throw new IllegalArgumentException("BUFFER_TOO_SMALL: output capacity overflow");
        }
        if (capacity > Integer.MAX_VALUE) {
            throw new IllegalArgumentException("BUFFER_TOO_SMALL: output capacity overflow");
        }
        return (int) capacity;
    }

    private int transitionFrames(double previousRatio, double newRatio) {
        if (inputFormat == AudioFormat.NOT_SET || inputFormat.sampleRate <= 0) {
            return 0;
        }
        // The ramp length scales with the ratio step: 40 ms keeps small
        // adjustments immediate, while a 1.00 -> 1.30 jump spreads over
        // ~115 ms and a full-range 0.70 -> 1.30 sweep is clamped at 160 ms.
        // The ramp drives the real per-block frame ratio in native code, not
        // a UI variable, and never touches the volume.
        double transitionSeconds = Math.min(
                0.160, 0.040 + 0.250 * Math.abs(newRatio - previousRatio));
        return Math.max(1, (int) Math.round(inputFormat.sampleRate * transitionSeconds));
    }

    private void ensurePcmStagingCapacity(int requiredBytes) {
        if (pcmStagingBuffer.capacity() >= requiredBytes) {
            return;
        }
        int capacity = growCapacity(INITIAL_PCM_CAPACITY_BYTES, requiredBytes);
        pcmStagingBuffer = ByteBuffer.allocateDirect(capacity).order(ByteOrder.nativeOrder());
    }

    private void ensurePcmOutputCapacity(int requiredBytes) {
        if (pcmOutputBuffer.capacity() >= requiredBytes) {
            return;
        }
        pcmOutputBuffer = ByteBuffer
                .allocateDirect(growCapacity(INITIAL_PCM_CAPACITY_BYTES, requiredBytes))
                .order(ByteOrder.nativeOrder());
    }

    private void preallocateRealtimeBuffers() {
        if (pcmStagingBuffer == EMPTY_BUFFER) {
            pcmStagingBuffer = ByteBuffer
                    .allocateDirect(INITIAL_PCM_CAPACITY_BYTES)
                    .order(ByteOrder.nativeOrder());
        }
        if (pcmOutputBuffer == EMPTY_BUFFER) {
            pcmOutputBuffer = ByteBuffer
                    .allocateDirect(INITIAL_PCM_CAPACITY_BYTES)
                    .order(ByteOrder.nativeOrder());
        }
        if (nativeInputBuffer == EMPTY_BUFFER) {
            nativeInputBuffer = ByteBuffer
                    .allocateDirect(INITIAL_PCM_CAPACITY_BYTES)
                    .order(ByteOrder.nativeOrder());
        }
        if (nativeOutputBuffer == EMPTY_BUFFER) {
            nativeOutputBuffer = ByteBuffer
                    .allocateDirect(INITIAL_PCM_CAPACITY_BYTES)
                    .order(ByteOrder.nativeOrder());
        }
    }

    private void ensureNativeInputCapacity(int requiredBytes) {
        if (nativeInputBuffer.capacity() >= requiredBytes) {
            return;
        }
        nativeInputBuffer = ByteBuffer
                .allocateDirect(growCapacity(INITIAL_PCM_CAPACITY_BYTES, requiredBytes))
                .order(ByteOrder.nativeOrder());
    }

    private void ensureNativeOutputCapacity(int requiredFrames) {
        int requiredBytes = checkedByteCount(
                requiredFrames, inputFormat.channelCount, FLOAT_BYTES_PER_SAMPLE);
        if (nativeOutputBuffer.capacity() >= requiredBytes) {
            return;
        }
        nativeOutputBuffer = ByteBuffer
                .allocateDirect(growCapacity(INITIAL_PCM_CAPACITY_BYTES, requiredBytes))
                .order(ByteOrder.nativeOrder());
    }

    private static int checkedByteCount(int frames, int channels, int bytesPerSample) {
        return checkedProduct(checkedProduct(frames, channels), bytesPerSample);
    }

    private static int checkedProduct(int left, int right) {
        long product = (long) left * (long) right;
        if (left < 0 || right < 0 || product > Integer.MAX_VALUE) {
            throw new IllegalArgumentException("BUFFER_TOO_SMALL: PCM buffer size overflow");
        }
        return (int) product;
    }

    private static int growCapacity(int initialCapacity, int requiredCapacity) {
        int capacity = Math.max(1, initialCapacity);
        while (capacity < requiredCapacity) {
            if (capacity > Integer.MAX_VALUE / 2) {
                return requiredCapacity;
            }
            capacity *= 2;
        }
        return capacity;
    }

    private static void validateOutputFrameCount(int outputFrames, int capacityFrames) {
        if (outputFrames < 0 || outputFrames > capacityFrames) {
            throw new IllegalStateException(
                    "NATIVE_PROCESSING_FAILED: invalid native output frame count");
        }
    }

    private static void validateRatio(double ratio) {
        if (Double.isNaN(ratio)
                || Double.isInfinite(ratio)
                || ratio < MIN_RATIO - RATIO_TOLERANCE
                || ratio > MAX_RATIO + RATIO_TOLERANCE) {
            throw new IllegalArgumentException("Tempo ratio must be between 0.70 and 1.30");
        }
    }

    private static boolean sameFormat(AudioFormat left, AudioFormat right) {
        return left != AudioFormat.NOT_SET
                && right != AudioFormat.NOT_SET
                && left.sampleRate == right.sampleRate
                && left.channelCount == right.channelCount
                && left.encoding == right.encoding;
    }

    private static String errorMessage(Throwable error) {
        String message = error.getMessage();
        return message == null || message.isEmpty()
                ? error.getClass().getSimpleName()
                : message;
    }

    /** Internal control-flow marker after the runtime has already latched the Sonic fallback. */
    private static final class NativeFallbackActivatedException extends RuntimeException {
        NativeFallbackActivatedException() {
            super("MEDIA3_FALLBACK");
        }
    }
}
