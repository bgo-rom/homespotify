#include "HomeSpotifyStretchEngine.h"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <string>
#include <vector>

using homespotify::stretch::HomeSpotifyStretchEngine;
using homespotify::stretch::StretchProfile;

namespace {

constexpr int kSampleRate = 48000;

void require(bool condition, const char *message) {
  if (!condition) {
    std::cerr << "FAIL: " << message << '\n';
    std::exit(1);
  }
}

std::vector<float> makeSine(std::size_t frames, int channels) {
  std::vector<float> input(frames * static_cast<std::size_t>(channels));
  for (std::size_t frame = 0; frame < frames; ++frame) {
    const float sample = static_cast<float>(
        0.2 * std::sin(2.0 * 3.141592653589793 * 440.0 *
                       static_cast<double>(frame) / kSampleRate));
    for (int channel = 0; channel < channels; ++channel) {
      input[frame * static_cast<std::size_t>(channels) +
            static_cast<std::size_t>(channel)] = sample;
    }
  }
  return input;
}

void exerciseDuration(double ratio, int channels) {
  constexpr std::size_t totalInputFrames = 48000;
  constexpr std::size_t chunkFrames = 1024;
  HomeSpotifyStretchEngine engine;
  engine.initialize(kSampleRate, channels);
  engine.setTempoRatio(ratio, 0);

  const std::vector<float> input = makeSine(totalInputFrames, channels);
  std::vector<float> rendered;
  std::size_t inputOffsetFrames = 0;
  std::size_t producedFrames = 0;
  while (inputOffsetFrames < totalInputFrames) {
    const std::size_t frames =
        std::min(chunkFrames, totalInputFrames - inputOffsetFrames);
    const std::size_t outputCapacity = static_cast<std::size_t>(
                                           std::ceil(frames / 0.70)) +
                                       8;
    std::vector<float> output(
        outputCapacity * static_cast<std::size_t>(channels));
    const float *chunk =
        input.data() + inputOffsetFrames * static_cast<std::size_t>(channels);
    const std::size_t produced = engine.process(
        chunk, frames * static_cast<std::size_t>(channels), frames,
        output.data(), output.size(), outputCapacity);
    rendered.insert(rendered.end(), output.begin(),
                    output.begin() +
                        static_cast<std::ptrdiff_t>(
                            produced * static_cast<std::size_t>(channels)));
    producedFrames += produced;
    inputOffsetFrames += frames;
  }

  const std::size_t flushFrames = engine.getExpectedOutputFrames(0);
  std::vector<float> tail(flushFrames * static_cast<std::size_t>(channels));
  const std::size_t flushed =
      engine.flush(tail.data(), tail.size(), flushFrames);
  rendered.insert(rendered.end(), tail.begin(), tail.end());
  producedFrames += flushed;

  const std::size_t expectedFrames = static_cast<std::size_t>(
      std::llround(static_cast<double>(totalInputFrames) / ratio));
  const std::size_t durationError = producedFrames > expectedFrames
                                        ? producedFrames - expectedFrames
                                        : expectedFrames - producedFrames;
  require(durationError <= 1,
          "streamed output duration must match media duration / ratio");
  require(engine.flush(tail.data(), tail.size(), flushFrames) == 0,
          "flush must be idempotent");

  std::size_t firstAudibleFrame = std::numeric_limits<std::size_t>::max();
  for (std::size_t frame = 0; frame < producedFrames; ++frame) {
    bool audible = false;
    for (int channel = 0; channel < channels; ++channel) {
      const float sample =
          rendered[frame * static_cast<std::size_t>(channels) +
                   static_cast<std::size_t>(channel)];
      require(std::isfinite(sample), "rendered PCM must remain finite");
      audible = audible || std::abs(sample) > 0.00001f;
    }
    if (audible) {
      firstAudibleFrame = frame;
      break;
    }
  }
  require(firstAudibleFrame < static_cast<std::size_t>(kSampleRate / 20),
          "outputSeek must avoid a large silent prefix");
  require(engine.getMetricsJson().find("\"processCount\":") !=
              std::string::npos,
          "metrics must expose process calls");

  engine.reset();
  require(std::abs(engine.getAppliedTempoRatio() - 1.0) < 0.000001,
          "reset must restore 1.00x");
  engine.dispose();
  engine.dispose();
}

void exerciseShortTrack() {
  constexpr int channels = 2;
  constexpr std::size_t inputFrames = 128;
  constexpr double ratio = 0.70;
  HomeSpotifyStretchEngine engine;
  engine.initialize(kSampleRate, channels);
  engine.setTempoRatio(ratio, 0);
  const std::vector<float> input = makeSine(inputFrames, channels);
  std::vector<float> initialOutput(512 * channels);
  require(engine.process(input.data(), input.size(), inputFrames,
                         initialOutput.data(), initialOutput.size(), 512) == 0,
          "a short track must remain in the startup prebuffer");

  const std::size_t flushFrames = engine.getExpectedOutputFrames(0);
  const std::size_t expectedFrames = static_cast<std::size_t>(
      std::llround(static_cast<double>(inputFrames) / ratio));
  require(flushFrames == expectedFrames,
          "short-track flush must preserve the requested duration");
  std::vector<float> tail(flushFrames * channels);
  require(engine.flush(tail.data(), tail.size(), flushFrames) == flushFrames,
          "short-track PCM must flush safely");
  require(std::all_of(tail.begin(), tail.end(),
                      [](float sample) { return std::isfinite(sample); }),
          "short-track PCM must remain finite");
}

} // namespace

void exerciseStableProductionProfile() {
  // Live ratio changes must never leave the stream on a stale profile: the
  // production mapping is a single calibrated configuration, so a slider
  // sweep 1.04 -> 1.30 keeps the same STFT geometry with no pending change.
  constexpr int channels = 2;
  HomeSpotifyStretchEngine engine;
  engine.initialize(kSampleRate, channels);
  engine.setTempoRatio(1.04, 0);
  require(engine.getProfile() == StretchProfile::musical,
          "an active stream must start on the production profile");
  const std::vector<float> input = makeSine(48000, channels);
  std::vector<float> output(
      static_cast<std::size_t>(std::ceil(48000 / 0.70) + 8) * channels);
  engine.process(input.data(), input.size(), 48000, output.data(),
                 output.size(), output.size() / channels);
  engine.setTempoRatio(1.30, kSampleRate / 25); // live change, 40 ms ramp
  require(engine.getProfile() == StretchProfile::musical,
          "a live ratio change must keep the production profile");
  require(engine.getMetricsJson().find("\"profileChangePending\":false") !=
              std::string::npos,
          "no profile change may stay pending after a live ratio change");
  engine.dispose();
}

void exerciseProfileOverride() {
  constexpr int channels = 2;
  HomeSpotifyStretchEngine engine;
  engine.initialize(kSampleRate, channels);
  engine.setProfileOverride(static_cast<int>(StretchProfile::transparent));
  engine.reset();
  engine.setTempoRatio(1.20, 0);
  require(engine.getProfile() == StretchProfile::transparent,
          "a dev override must be applied at the reset boundary");
  engine.setProfileOverride(-1);
  engine.reset();
  engine.setTempoRatio(1.20, 0);
  require(engine.getProfile() == StretchProfile::musical,
          "clearing the override must restore the production profile");
  engine.dispose();
}

void exerciseStereoIntegrity() {
  // A hard-panned source must stay hard-panned: both channels run in one
  // multichannel Signalsmith instance with identical frame counts.
  constexpr int channels = 2;
  constexpr std::size_t frames = 96000;
  HomeSpotifyStretchEngine engine;
  engine.initialize(kSampleRate, channels);
  engine.setTempoRatio(1.20, 0);
  std::vector<float> input(frames * channels, 0.0f);
  for (std::size_t frame = 0; frame < frames; ++frame) {
    input[frame * channels] = static_cast<float>(
        0.4 * std::sin(2.0 * 3.141592653589793 * 330.0 *
                       static_cast<double>(frame) / kSampleRate));
  }
  std::vector<float> rendered;
  std::size_t offset = 0;
  const std::size_t capacity =
      static_cast<std::size_t>(std::ceil(1024 / 0.70)) + 8;
  std::vector<float> chunkOut(capacity * channels);
  while (offset < frames) {
    const std::size_t n = std::min<std::size_t>(1024, frames - offset);
    const std::size_t produced = engine.process(
        input.data() + offset * channels, n * channels, n, chunkOut.data(),
        chunkOut.size(), capacity);
    rendered.insert(rendered.end(), chunkOut.begin(),
                    chunkOut.begin() +
                        static_cast<std::ptrdiff_t>(produced * channels));
    offset += n;
  }
  double leftEnergy = 0;
  double rightEnergy = 0;
  for (std::size_t frame = 0; frame < rendered.size() / channels; ++frame) {
    leftEnergy += rendered[frame * channels] * rendered[frame * channels];
    rightEnergy +=
        rendered[frame * channels + 1] * rendered[frame * channels + 1];
  }
  require(leftEnergy > 0, "panned stereo must produce left output");
  require(rightEnergy < leftEnergy * 0.0001,
          "silent right channel must stay at least 40 dB below left");
  engine.dispose();
}

void exerciseRampAccounting() {
  // A mid-stream ramp must keep long-term frame accounting exact: after the
  // ramp completes, incremental output must match the new ratio without a
  // growing error (fractional accumulator across ramp segments).
  constexpr int channels = 2;
  HomeSpotifyStretchEngine engine;
  engine.initialize(kSampleRate, channels);
  engine.setTempoRatio(0.80, 0);
  const std::vector<float> input = makeSine(48000, channels);
  const std::size_t capacity =
      static_cast<std::size_t>(std::ceil(1024 / 0.70)) + 8;
  std::vector<float> chunkOut(capacity * channels);
  auto streamSeconds = [&](double seconds) {
    std::size_t produced = 0;
    std::size_t remaining =
        static_cast<std::size_t>(seconds * kSampleRate);
    while (remaining > 0) {
      const std::size_t n = std::min<std::size_t>(1024, remaining);
      produced += engine.process(input.data(), n * channels, n,
                                 chunkOut.data(), chunkOut.size(), capacity);
      remaining -= n;
    }
    return produced;
  };
  streamSeconds(2.0);
  engine.setTempoRatio(1.25, kSampleRate / 10); // 100 ms ramp
  streamSeconds(1.0);                            // ramp fully completes
  const std::size_t steadyProduced = streamSeconds(10.0);
  const double expected = 10.0 * kSampleRate / 1.25;
  require(std::abs(static_cast<double>(steadyProduced) - expected) <= 2.0,
          "steady-state output after a ramp must match the new ratio");
  engine.dispose();
}

int main() {
  for (const double ratio : {0.70, 0.80, 0.95, 1.05, 1.20, 1.30}) {
    require(HomeSpotifyStretchEngine::selectProfile(ratio) ==
                StretchProfile::musical,
            "every active ratio must map to the single production profile");
  }

  for (const double invalid : {0.69, 1.31}) {
    bool rejected = false;
    try {
      (void)HomeSpotifyStretchEngine::selectProfile(invalid);
    } catch (const std::invalid_argument &) {
      rejected = true;
    }
    require(rejected, "out-of-range ratios must be rejected");
  }

  exerciseDuration(0.70, 2);
  exerciseDuration(0.80, 2);
  exerciseDuration(1.20, 2);
  exerciseDuration(1.30, 2);
  exerciseDuration(0.80, 1);
  exerciseShortTrack();
  exerciseStableProductionProfile();
  exerciseProfileOverride();
  exerciseStereoIntegrity();
  exerciseRampAccounting();

  HomeSpotifyStretchEngine invalidFormatEngine;
  bool multichannelRejected = false;
  try {
    invalidFormatEngine.initialize(kSampleRate, 6);
  } catch (const std::invalid_argument &) {
    multichannelRejected = true;
  }
  require(multichannelRejected, "multichannel PCM must be rejected");

  std::cout << "OK: HomeSpotify Stretch streaming contract\n";
  return 0;
}
