#include "HomeSpotifyStretchEngine.h"

#include <cmath>
#include <cstdlib>
#include <iostream>
#include <stdexcept>
#include <vector>

using homespotify::stretch::HomeSpotifyStretchEngine;
using homespotify::stretch::StretchProfile;

namespace {

void require(bool condition, const char *message) {
  if (!condition) {
    std::cerr << "FAIL: " << message << '\n';
    std::exit(1);
  }
}

} // namespace

int main() {
  require(HomeSpotifyStretchEngine::selectProfile(1.00) ==
              StretchProfile::transparent,
          "1.00 must select TRANSPARENT");
  require(HomeSpotifyStretchEngine::selectProfile(0.80) ==
              StretchProfile::musical,
          "0.80 must select MUSICAL");
  require(HomeSpotifyStretchEngine::selectProfile(1.20) ==
              StretchProfile::musical,
          "1.20 must select MUSICAL");
  require(HomeSpotifyStretchEngine::selectProfile(0.70) ==
              StretchProfile::extremeHq,
          "0.70 must select EXTREME_HQ");
  require(HomeSpotifyStretchEngine::selectProfile(1.30) ==
              StretchProfile::extremeHq,
          "1.30 must select EXTREME_HQ");

  bool invalidRatioRejected = false;
  try {
    (void)HomeSpotifyStretchEngine::selectProfile(0.69);
  } catch (const std::invalid_argument &) {
    invalidRatioRejected = true;
  }
  require(invalidRatioRejected, "0.69 must be rejected");

  HomeSpotifyStretchEngine engine;
  if (!engine.isAvailable()) {
    bool unavailableRejected = false;
    try {
      engine.initialize(48000, 2);
    } catch (const std::runtime_error &error) {
      unavailableRejected =
          std::string(error.what()).find("NATIVE_LIBRARY_UNAVAILABLE") !=
          std::string::npos;
    }
    require(unavailableRejected,
            "fallback initialize must report NATIVE_LIBRARY_UNAVAILABLE");
    std::cout << "OK: pinned vendor absent and fallback contract valid\n";
    return 0;
  }

  constexpr int sampleRate = 48000;
  constexpr int channels = 2;
  constexpr std::size_t inputFrames = 2048;
  engine.initialize(sampleRate, channels);
  engine.setTempoRatio(0.80);
  const std::size_t required = engine.getRequiredOutputFrames(inputFrames);
  std::vector<float> input(inputFrames * channels);
  for (std::size_t frame = 0; frame < inputFrames; ++frame) {
    const float sample = static_cast<float>(
        0.25 * std::sin(2.0 * 3.141592653589793 * 440.0 * frame / sampleRate));
    input[frame * channels] = sample;
    input[frame * channels + 1] = sample;
  }
  std::vector<float> output(required * channels);
  const std::size_t produced =
      engine.process(input.data(), input.size(), inputFrames, output.data(),
                     output.size(), required);
  require(produced > inputFrames, "0.80 must produce more frames");
  require(produced <= required, "output must stay within capacity");
  require(engine.getLatencyFrames() > 0, "latency must be reported");
  const std::size_t flushCapacity = engine.getRequiredOutputFrames(0);
  std::vector<float> tail(flushCapacity * channels);
  const std::size_t flushed =
      engine.flush(tail.data(), tail.size(), flushCapacity);
  require(flushed == flushCapacity, "flush must return its announced tail");
  require(engine.getRequiredOutputFrames(0) == 0,
          "second flush must announce no tail");
  engine.reset();
  require(std::abs(engine.getAppliedRatio() - 1.0) < 0.000001,
          "reset must restore 1.00");
  engine.dispose();
  std::cout << "OK: HomeSpotify Stretch native contract\n";
  return 0;
}
