# HomeSpotify Stretch Engine POC

This package is an isolated Android/native proof of concept for processing
explicit PCM float buffers with Signalsmith Stretch. It is not connected to the
HomeSpotify player, queue, media notification, Discover or speed controls.

Production integration now lives independently in
`packages/homespotify_just_audio`; it does not import or execute this research
directory. Nothing in this directory is initialized automatically at
application startup, and this POC remains useful only for isolated fixtures and
comparison.

## Manual upstream vendor step

The official DSP headers are deliberately not fetched by Gradle or at runtime.
From a network-enabled developer shell, run:

```powershell
pwsh -NoProfile -File .\tools\homespotify-stretch-poc\tool\vendor_signalsmith.ps1
```

The script checks out exact commits from Signalsmith's official non-GitHub
repositories, verifies the declared Stretch version and MIT license markers,
copies only the required headers/licenses, and generates SHA-256 hashes in
`VENDOR_MANIFEST.json`. Any checkout, provenance or input-file mismatch stops
the operation with an explicit error.

See
`android/src/main/cpp/third_party/signalsmith_stretch/UPSTREAM.md` for the exact
versions and licensing record.

## Scope and safety

- target ABI: Android `arm64-v8a`;
- internal samples: 32-bit float PCM, mono or stereo;
- no decoder, Media3 interception or permanent parallel player;
- no original music-file modification;
- no gain, normalization, ReplayGain, equalizer or backend transcoding;
- fixture outputs are developer-only test artifacts and must not be committed.

Signalsmith is not considered production-ready in HomeSpotify until native
compilation, fixture measurements, listening tests and real-device CPU/latency
validation have all passed.

## Isolated architecture

```text
NativeStretchPoc (Dart, explicit calls only)
  -> MethodChannel com.homespotify/stretch_poc
  -> lazy Kotlin single-thread executor
  -> JNI handle registry
  -> HomeSpotifyStretchEngine (float32 planar internally)
  -> pinned Signalsmith Stretch headers
```

The package is intentionally absent from the mobile application's `pubspec.yaml`
and Android settings. Registering the plugin in a future developer host would
still not load the shared library: `System.loadLibrary` runs only after an
explicit POC method call. PCM processing is moved off Android's main thread.
MethodChannel copies buffers, so this bridge is suitable for short fixtures,
not for the eventual real-time audio path.

## Native contract

`HomeSpotifyStretchEngine` exposes initialization, tempo selection, bounded
interleaved PCM processing, flush, reset, latency/output-capacity queries,
engine information and idempotent disposal. Only mono/stereo float32 PCM from
8–192 kHz is accepted. A processing call accepts 2–480,000 input frames.

Tempo is limited to 0.70–1.30. Pitch is not exposed by the bridge and is fixed
with `setTransposeFactor(1.0)`. Signalsmith has no `setTempoRatio`: the wrapper
derives output-frame counts from the requested playback ratio, retains a
fractional frame accumulator and ramps ratio changes over 40 ms in 5 ms
segments once a stream is active. A ratio selected before the first buffer is
applied directly, so fixture labels remain exact. It never processes in-place,
clips, rescales or normalizes samples.

A profile change would reconfigure Signalsmith and clear its history. Therefore
the requested profile is selected before the first buffer. During an active
stream, a cross-profile request ramps the ratio with the current profile and is
reported as pending; it does not reset the stream. `reset()` deliberately
discards that pending profile and returns to 1.00x/`TRANSPARENT`. Set the next
ratio after reset and before its first PCM buffer to select its matching profile.

## Experimental HomeSpotify profiles

| Profile | Ratio selection | Signalsmith configuration |
| --- | --- | --- |
| `TRANSPARENT` | 0.95–1.05 | `presetCheaper(channels, sampleRate, true)`; nominal 100/40 ms block/interval |
| `MUSICAL` | 0.80–0.94 and 1.06–1.20 | `presetDefault(channels, sampleRate, true)`; nominal 120/30 ms |
| `EXTREME_HQ` | 0.70–0.79 and 1.21–1.30 | `configure(channels, 160 ms, 20 ms, true)` |

`splitComputation=true` spreads spectral work more evenly but adds one interval
of output latency. The library exposes no public "transient quality" control,
so none is invented here. Formant APIs are deliberately unused because this POC
does not transpose pitch. `EXTREME_HQ` is an internal experiment name, not an
upstream preset or a quality guarantee. Actual latency comes from
`inputLatency()` + `outputLatency()` and must be measured after the vendor is
present. Upstream describes its best-result range as roughly 0.75x–1.5x, so the
required 0.70x boundary is explicitly experimental and needs listening/device
validation. No content or musical-style detector exists in this first POC.

## Developer fixture comparison

The native target `homespotify_stretch_fixture_compare` synthesizes a short
48 kHz stereo PCM buffer and writes only into a path containing a
`test`, `temp`, `tmp` or `artifacts` path segment:

- `original.wav`;
- `signalsmith_0_70x.wav`;
- `signalsmith_0_80x.wav`;
- `signalsmith_1_20x.wav`;
- `signalsmith_1_30x.wav`.

The files are IEEE float32 WAV test artifacts; there is no WAV/FLAC decoder and
no source music file to replace. Each run reports requested/applied ratio,
format, input/output frames, native duration, real-time factor, announced
latency, peaks and out-of-range sample count. `StretchComparisonRunner` exposes
the same explicit workflow to a Flutter test/developer host and restricts its
outputs to a test/temp/artifacts directory.

The comparison WAVs intentionally retain the processor's pre-roll/tail. They
are raw POC artifacts, not sample-aligned masters; reported latency must be
considered during listening comparisons.

## Current validation boundary

The environment used for this POC could not download the upstream headers. The
arm64-v8a shared library and host contract test therefore compile in the safe
`NATIVE_LIBRARY_UNAVAILABLE` fallback mode. This validates CMake, JNI symbols,
buffer/error plumbing and absence handling, but not Signalsmith DSP output,
latency, CPU cost or listening quality. Run the manual vendor step first; then
re-run direct CMake/NDK compilation and the fixture tool. No Gradle or APK build
is required for that gate.

The exact next production step, after fixture/listening/device validation, is a
separate Media3 experiment which inserts this processor into the single
`DefaultAudioSink` PCM chain while preserving the existing player, queue and
timeline. The MethodChannel buffer bridge must not be used as that real-time
path.
