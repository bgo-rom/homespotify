package com.homespotify.audio.stretch;

import android.content.Context;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import android.os.Build;
import android.os.Bundle;
import java.util.LinkedHashMap;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.AtomicReference;

/** Lock-free diagnostic state shared by one ExoPlayer stretch chain. */
public final class HomeSpotifyStretchRuntime {
    public static final String ENGINE_SIGNALSMITH = "signalsmith";
    public static final String ENGINE_MEDIA3 = "media3";
    public static final String MODE_STRETCH = "HOMESPOTIFY_STRETCH";
    public static final String MODE_FALLBACK = "MEDIA3_FALLBACK";

    private static final String META_DATA_ENGINE = "HOMESPOTIFY_STRETCH_ENGINE";
    private static final AtomicReference<HomeSpotifyStretchRuntime> controlTarget =
            new AtomicReference<>();

    /** Dev/A-B override: -1 auto, 0..2 native profile ordinal, 3 forced Media3. */
    public static final int OVERRIDE_AUTO = -1;
    public static final int OVERRIDE_MEDIA3 = 3;

    private final boolean signalsmithRequested;
    private final boolean potentiallySupportedAbi;
    private final AtomicBoolean fallbackLatched = new AtomicBoolean();
    private final AtomicBoolean seekResetRequested = new AtomicBoolean();
    private final AtomicBoolean overloadFallbackRequested = new AtomicBoolean();
    private final AtomicBoolean fallbackClearRequested = new AtomicBoolean();
    private volatile int profileOverride = OVERRIDE_AUTO;
    private final AtomicLong pcmFramesProcessed = new AtomicLong();
    private final AtomicLong dspTotalMicros = new AtomicLong();
    private final AtomicLong dspCallCount = new AtomicLong();
    private final AtomicLong maxDspMicros = new AtomicLong();
    private final AtomicLong fallbackCount = new AtomicLong();
    private final AtomicLong underrunCount = new AtomicLong();
    private final AtomicInteger overloadStreak = new AtomicInteger();

    private volatile String engineMode;
    private volatile boolean active;
    private volatile double requestedRatio = 1.0;
    private volatile double appliedRatio = 1.0;
    private volatile double nativeAppliedRatio = 1.0;
    private volatile String profile = "TRANSPARENT";
    private volatile int latencyFrames;
    private volatile int sampleRate;
    private volatile int channels;
    private volatile String lastError;
    private volatile String nativeMetrics;

    public HomeSpotifyStretchRuntime(Context context) {
        this(
                !ENGINE_MEDIA3.equals(readConfiguredEngine(context)),
                isPotentiallySupportedAbi());
    }

    /** Constructor used by local JVM contract tests without an Android runtime. */
    HomeSpotifyStretchRuntime(boolean signalsmithRequested, boolean potentiallySupportedAbi) {
        this.signalsmithRequested = signalsmithRequested;
        this.potentiallySupportedAbi = potentiallySupportedAbi;
        engineMode = signalsmithRequested && potentiallySupportedAbi
                ? MODE_STRETCH
                : MODE_FALLBACK;
        if (!signalsmithRequested) {
            fallbackLatched.set(true);
        } else if (!potentiallySupportedAbi) {
            fallbackLatched.set(true);
            lastError = "UNSUPPORTED_ABI: HomeSpotify Stretch is not packaged for this ABI";
        }
    }

    public void markControlTarget() {
        controlTarget.set(this);
    }

    public void setRequestedRatio(double ratio) {
        requestedRatio = ratio;
        profile = selectProfile(ratio);
        if (Math.abs(ratio - 1.0) < HomeSpotifyStretchAudioProcessor.RATIO_TOLERANCE) {
            active = false;
            appliedRatio = 1.0;
            nativeAppliedRatio = 1.0;
        }
    }

    public boolean canAttemptNative() {
        return signalsmithRequested && potentiallySupportedAbi && !fallbackLatched.get();
    }

    public boolean isFallbackLatched() {
        return fallbackLatched.get();
    }

    public void recordNativeActive(
            double configuredRatio,
            double nativeAppliedRatio,
            int latencyFrames,
            int sampleRate,
            int channels) {
        engineMode = MODE_STRETCH;
        active = Math.abs(requestedRatio - 1.0)
                >= HomeSpotifyStretchAudioProcessor.RATIO_TOLERANCE;
        // A successful setRatio call is the transactional acceptance point used by Dart. The
        // native value may still be traversing its short smoothing ramp (or playback may be
        // paused), so expose that instantaneous value separately rather than making persistence
        // wait for PCM to advance.
        this.appliedRatio = configuredRatio;
        this.nativeAppliedRatio = nativeAppliedRatio;
        this.latencyFrames = Math.max(0, latencyFrames);
        this.sampleRate = sampleRate;
        this.channels = channels;
        lastError = null;
    }

    public void recordFallbackActive(String reason) {
        if (fallbackLatched.compareAndSet(false, true)) {
            fallbackCount.incrementAndGet();
        }
        engineMode = MODE_FALLBACK;
        active = Math.abs(requestedRatio - 1.0)
                >= HomeSpotifyStretchAudioProcessor.RATIO_TOLERANCE;
        appliedRatio = requestedRatio;
        nativeAppliedRatio = requestedRatio;
        latencyFrames = 0;
        if (reason != null && !reason.isEmpty()) {
            lastError = sanitizeError(reason);
        }
    }

    public void recordUnitSpeed() {
        active = false;
        appliedRatio = 1.0;
        nativeAppliedRatio = 1.0;
        profile = "TRANSPARENT";
        latencyFrames = 0;
        if (fallbackLatched.get()) {
            engineMode = MODE_FALLBACK;
        }
    }

    public void recordError(String reason) {
        if (reason != null && !reason.isEmpty()) {
            lastError = sanitizeError(reason);
        }
    }

    public void recordDsp(
            long inputFrames, long elapsedMicros, int sampleRate, double tempoRatio) {
        pcmFramesProcessed.addAndGet(Math.max(0L, inputFrames));
        dspTotalMicros.addAndGet(Math.max(0L, elapsedMicros));
        dspCallCount.incrementAndGet();
        updateMaximum(maxDspMicros, Math.max(0L, elapsedMicros));

        // Media3 1.4.1 exposes no portable AudioTrack underrun callback here. Three consecutive
        // real-time deadline misses are counted as a detected underrun risk, never per-buffer log
        // spam. This remains a conservative diagnostic rather than an AudioTrack hardware count.
        if (sampleRate > 0 && inputFrames > 0 && tempoRatio > 0) {
            long expectedOutputFrames =
                    (long) Math.ceil(inputFrames / Math.max(0.70, tempoRatio));
            long budgetMicros = (expectedOutputFrames * 1_000_000L) / sampleRate;
            if (elapsedMicros > budgetMicros) {
                int misses = overloadStreak.incrementAndGet();
                if (misses == 3) {
                    underrunCount.incrementAndGet();
                }
                if (misses >= 6) {
                    overloadFallbackRequested.set(true);
                }
            } else {
                overloadStreak.set(0);
            }
        }
    }

    public void updateNativeSnapshot(String metrics) {
        nativeMetrics = metrics;
    }

    public void requestSeekReset() {
        seekResetRequested.set(true);
    }

    public boolean consumeSeekResetRequest() {
        return seekResetRequested.getAndSet(false);
    }

    public boolean consumeOverloadFallbackRequest() {
        return overloadFallbackRequested.getAndSet(false);
    }

    public int getProfileOverride() {
        return profileOverride;
    }

    /** Dev/A-B only. Takes effect at the next PCM boundary (flush/seek). */
    public void setProfileOverride(int override) {
        if (override < OVERRIDE_AUTO || override > OVERRIDE_MEDIA3) {
            return;
        }
        int previous = profileOverride;
        profileOverride = override;
        if (previous == OVERRIDE_MEDIA3 && override != OVERRIDE_MEDIA3) {
            // Leaving the forced-Media3 comparison must be able to unlatch the
            // fallback; a real (non-dev) latch reason still re-latches itself.
            fallbackClearRequested.set(true);
        }
    }

    public boolean consumeFallbackClearRequest() {
        return fallbackClearRequested.getAndSet(false);
    }

    /** Dev/A-B only: drops the latch so the next boundary can retry Signalsmith. */
    public boolean unlatchFallback() {
        if (!signalsmithRequested || !potentiallySupportedAbi) {
            return false;
        }
        fallbackLatched.set(false);
        overloadStreak.set(0);
        engineMode = MODE_STRETCH;
        return true;
    }

    public void clearControlTarget() {
        controlTarget.compareAndSet(this, null);
    }

    public Map<String, Object> getStatusSnapshot() {
        long calls = dspCallCount.get();
        long totalMicros = dspTotalMicros.get();
        Map<String, Object> status = new LinkedHashMap<>();
        status.put("engineMode", engineMode);
        status.put("available", NativeStretchBridge.isLoadedAndAvailable());
        status.put("active", active);
        status.put("requestedRatio", requestedRatio);
        status.put("appliedRatio", appliedRatio);
        status.put("nativeAppliedRatio", nativeAppliedRatio);
        status.put("profile", profile);
        status.put("latencyFrames", latencyFrames);
        status.put(
                "latencyMs",
                sampleRate > 0 ? (latencyFrames * 1000.0) / sampleRate : 0.0);
        status.put("sampleRate", sampleRate);
        status.put("channels", channels);
        status.put("pcmFramesProcessed", pcmFramesProcessed.get());
        status.put("averageDspMicros", calls == 0 ? 0.0 : (double) totalMicros / calls);
        status.put("maxDspMicros", maxDspMicros.get());
        status.put("fallbackCount", fallbackCount.get());
        status.put("underrunCount", underrunCount.get());
        status.put("profileOverride", profileOverride);
        String effectiveError = lastError;
        if (effectiveError == null) {
            effectiveError = NativeStretchBridge.getLoadError();
        }
        status.put("lastError", effectiveError);
        status.put("nativeMetrics", nativeMetrics);
        return status;
    }

    public static Map<String, Object> getControlTargetStatus() {
        HomeSpotifyStretchRuntime runtime = controlTarget.get();
        if (runtime != null) {
            return runtime.getStatusSnapshot();
        }
        Map<String, Object> status = new LinkedHashMap<>();
        status.put("engineMode", MODE_FALLBACK);
        status.put("available", NativeStretchBridge.isLoadedAndAvailable());
        status.put("active", false);
        status.put("requestedRatio", 1.0);
        status.put("appliedRatio", 1.0);
        status.put("nativeAppliedRatio", 1.0);
        status.put("profile", "TRANSPARENT");
        status.put("latencyFrames", 0);
        status.put("latencyMs", 0.0);
        status.put("sampleRate", 0);
        status.put("channels", 0);
        status.put("pcmFramesProcessed", 0L);
        status.put("averageDspMicros", 0.0);
        status.put("maxDspMicros", 0L);
        status.put("fallbackCount", 0L);
        status.put("underrunCount", 0L);
        status.put("profileOverride", OVERRIDE_AUTO);
        status.put("lastError", NativeStretchBridge.getLoadError());
        status.put("nativeMetrics", null);
        return status;
    }

    /** Dev/A-B only: sets the override on the currently controlled player. */
    public static boolean setControlTargetProfileOverride(int override) {
        HomeSpotifyStretchRuntime runtime = controlTarget.get();
        if (runtime == null) {
            return false;
        }
        runtime.setProfileOverride(override);
        return true;
    }

    public static boolean requestControlTargetSeekReset() {
        HomeSpotifyStretchRuntime runtime = controlTarget.get();
        if (runtime == null) {
            return false;
        }
        runtime.requestSeekReset();
        return true;
    }

    private static String readConfiguredEngine(Context context) {
        try {
            ApplicationInfo info = context.getPackageManager().getApplicationInfo(
                    context.getPackageName(), PackageManager.GET_META_DATA);
            Bundle metadata = info.metaData;
            if (metadata == null) {
                return ENGINE_SIGNALSMITH;
            }
            Object raw = metadata.get(META_DATA_ENGINE);
            if (raw == null) {
                return ENGINE_SIGNALSMITH;
            }
            String value = String.valueOf(raw).trim().toLowerCase(Locale.ROOT);
            return ENGINE_MEDIA3.equals(value) ? ENGINE_MEDIA3 : ENGINE_SIGNALSMITH;
        } catch (PackageManager.NameNotFoundException error) {
            return ENGINE_SIGNALSMITH;
        }
    }

    private static boolean isPotentiallySupportedAbi() {
        if (Build.VERSION.SDK_INT >= 21) {
            for (String abi : Build.SUPPORTED_ABIS) {
                if ("arm64-v8a".equals(abi) || "x86_64".equals(abi)) {
                    return true;
                }
            }
            return false;
        }
        return "arm64-v8a".equals(Build.CPU_ABI) || "x86_64".equals(Build.CPU_ABI);
    }

    private static String selectProfile(double ratio) {
        // Mirrors the native production mapping: one calibrated configuration
        // for every active ratio; 1.00x is a full DSP bypass. Range-based
        // profiles cannot be applied during a live ratio change and silently
        // latched the first profile (see HomeSpotifyStretchEngine).
        if (Math.abs(ratio - 1.0) < HomeSpotifyStretchAudioProcessor.RATIO_TOLERANCE) {
            return "TRANSPARENT";
        }
        return "MUSICAL";
    }

    private static String sanitizeError(String message) {
        String sanitized = message.replace('\n', ' ').replace('\r', ' ');
        return sanitized.length() <= 300 ? sanitized : sanitized.substring(0, 300);
    }

    private static void updateMaximum(AtomicLong target, long candidate) {
        long current = target.get();
        while (candidate > current && !target.compareAndSet(current, candidate)) {
            current = target.get();
        }
    }
}
