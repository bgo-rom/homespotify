package com.homespotify.audio.stretch;

import java.nio.ByteBuffer;

/**
 * Lazy JNI entry point for the HomeSpotify Stretch Engine.
 *
 * <p>Loading is deliberately triggered only from the playback thread after a non-unit tempo has
 * been requested and a supported PCM format is known. Merely registering the Flutter plugin or
 * constructing an ExoPlayer never loads the native library.
 */
public final class NativeStretchBridge {
    private static final String LIBRARY_NAME = "homespotify_stretch";

    private enum LoadState {
        NOT_ATTEMPTED,
        AVAILABLE,
        UNAVAILABLE
    }

    private static volatile LoadState loadState = LoadState.NOT_ATTEMPTED;
    private static volatile String loadError;

    private NativeStretchBridge() {
    }

    /** Called at most once, from the playback thread, and never from application startup. */
    static boolean ensureLoaded() {
        LoadState state = loadState;
        if (state != LoadState.NOT_ATTEMPTED) {
            return state == LoadState.AVAILABLE;
        }
        synchronized (NativeStretchBridge.class) {
            state = loadState;
            if (state != LoadState.NOT_ATTEMPTED) {
                return state == LoadState.AVAILABLE;
            }
            try {
                System.loadLibrary(LIBRARY_NAME);
                if (!isAvailable()) {
                    loadError = "NATIVE_LIBRARY_UNAVAILABLE: Signalsmith DSP is not available";
                    loadState = LoadState.UNAVAILABLE;
                    return false;
                }
                loadState = LoadState.AVAILABLE;
                return true;
            } catch (UnsatisfiedLinkError | RuntimeException error) {
                loadError = sanitizeError(error);
                loadState = LoadState.UNAVAILABLE;
                return false;
            }
        }
    }

    static boolean isLoadedAndAvailable() {
        return loadState == LoadState.AVAILABLE;
    }

    static String getLoadError() {
        return loadError;
    }

    private static String sanitizeError(Throwable error) {
        String message = error.getMessage();
        if (message == null || message.isEmpty()) {
            message = error.getClass().getSimpleName();
        }
        // JNI diagnostics must never turn into unbounded or path-heavy log payloads.
        message = message.replace('\n', ' ').replace('\r', ' ');
        return message.length() <= 300 ? message : message.substring(0, 300);
    }

    public static native long create();

    public static native boolean isAvailable();

    public static native void initialize(long handle, int sampleRate, int channels);

    public static native void setRatio(long handle, double ratio, int transitionFrames);

    /** Dev/A-B only: -1 restores production profile selection, 0..2 pins a profile. */
    public static native void setProfileOverride(long handle, int profileOrdinal);

    public static native int processDirect(
            long handle,
            ByteBuffer input,
            int inputFrames,
            ByteBuffer output,
            int outputCapacityFrames);

    public static native int flushDirect(
            long handle, ByteBuffer output, int outputCapacityFrames);

    public static native void reset(long handle);

    public static native int getLatency(long handle);

    public static native double getApplied(long handle);

    public static native String getMetrics(long handle);

    public static native void dispose(long handle);
}
