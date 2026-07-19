package com.homespotify.audio.stretch;

import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

/** Read-only diagnostic channel plus asynchronous seek-reset and dev A/B requests. */
public final class HomeSpotifyStretchDiagnostics implements MethodChannel.MethodCallHandler {
    public static final String CHANNEL_NAME = "com.homespotify/stretch_engine";

    @Override
    public void onMethodCall(MethodCall call, MethodChannel.Result result) {
        switch (call.method) {
        case "getStatus":
            // This is a Java snapshot only. JNI is never called from the Flutter/main thread.
            result.success(HomeSpotifyStretchRuntime.getControlTargetStatus());
            break;
        case "resetForSeek":
            result.success(HomeSpotifyStretchRuntime.requestControlTargetSeekReset());
            break;
        case "setProfileOverride": {
            // Dev A/B only. Stored on the runtime; the audio thread applies it
            // at the next PCM boundary (the lab screen forces an in-place seek).
            Integer override = call.argument("override");
            result.success(override != null
                    && HomeSpotifyStretchRuntime.setControlTargetProfileOverride(override));
            break;
        }
        default:
            result.notImplemented();
            break;
        }
    }
}
