# HomeSpotify local fork of just_audio 0.10.6

This package is a source-pinned local fork of `just_audio` 0.10.6. The upstream
MIT and bundled ExoPlayer/Media3 license notices remain in `LICENSE`.

HomeSpotify changes are intentionally limited to Android:

- inject a custom `DefaultAudioSink` through `DefaultRenderersFactory`;
- replace the default Sonic-only playback-parameter chain with the mutually
  exclusive HomeSpotify Stretch / Media3 fallback chain;
- compile the pinned Signalsmith Stretch 1.3.2 and Linear 0.3.1 sources;
- expose non-sensitive engine diagnostics over
  `com.homespotify/stretch_engine`.

The public Dart API and non-Android implementations remain upstream 0.10.6.
Never edit the global Pub cache; update this directory deliberately and review
the Android delta when rebasing onto a newer upstream release.
