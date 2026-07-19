#include "HomeSpotifyStretchEngine.h"

#include <algorithm>
#include <array>
#include <cctype>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

using homespotify::stretch::HomeSpotifyStretchEngine;

constexpr int kSampleRate = 48000;
constexpr int kChannels = 2;
constexpr double kPi = 3.14159265358979323846;

void writeLittleEndian32(std::ofstream &output, std::uint32_t value) {
  const std::array<char, 4> bytes{
      static_cast<char>(value & 0xff),
      static_cast<char>((value >> 8) & 0xff),
      static_cast<char>((value >> 16) & 0xff),
      static_cast<char>((value >> 24) & 0xff),
  };
  output.write(bytes.data(), static_cast<std::streamsize>(bytes.size()));
}

void writeLittleEndian16(std::ofstream &output, std::uint16_t value) {
  const std::array<char, 2> bytes{
      static_cast<char>(value & 0xff),
      static_cast<char>((value >> 8) & 0xff),
  };
  output.write(bytes.data(), static_cast<std::streamsize>(bytes.size()));
}

void writeFloatWav(const std::filesystem::path &path,
                   const std::vector<float> &samples) {
  std::ofstream output(path, std::ios::binary | std::ios::trunc);
  if (!output) {
    throw std::runtime_error("cannot create fixture artifact: " +
                             path.string());
  }
  const std::uint32_t dataBytes =
      static_cast<std::uint32_t>(samples.size() * sizeof(float));
  output.write("RIFF", 4);
  writeLittleEndian32(output, 36 + dataBytes);
  output.write("WAVEfmt ", 8);
  writeLittleEndian32(output, 16);
  writeLittleEndian16(output, 3); // IEEE float PCM.
  writeLittleEndian16(output, kChannels);
  writeLittleEndian32(output, kSampleRate);
  writeLittleEndian32(output, kSampleRate * kChannels * sizeof(float));
  writeLittleEndian16(output, kChannels * sizeof(float));
  writeLittleEndian16(output, 32);
  output.write("data", 4);
  writeLittleEndian32(output, dataBytes);
  output.write(reinterpret_cast<const char *>(samples.data()),
               static_cast<std::streamsize>(dataBytes));
}

std::vector<float> makeFixture() {
  constexpr std::size_t frames = kSampleRate / 4;
  std::vector<float> fixture(frames * kChannels);
  for (std::size_t frame = 0; frame < frames; ++frame) {
    const double time = static_cast<double>(frame) / kSampleRate;
    const float tone =
        static_cast<float>(0.22 * std::sin(2 * kPi * 110 * time) +
                           0.16 * std::sin(2 * kPi * 440 * time));
    const float transient = (frame % 2400 < 8) ? 0.18f : 0.0f;
    fixture[frame * kChannels] = tone + transient;
    fixture[frame * kChannels + 1] = tone - transient;
  }
  return fixture;
}

double peak(const std::vector<float> &samples) {
  double result = 0;
  for (const float sample : samples) {
    result = std::max(result, std::abs(static_cast<double>(sample)));
  }
  return result;
}

std::size_t outOfRangeCount(const std::vector<float> &samples) {
  return static_cast<std::size_t>(
      std::count_if(samples.begin(), samples.end(), [](float sample) {
        return sample < -1.0f || sample > 1.0f;
      }));
}

std::string ratioFileName(double ratio) {
  std::ostringstream name;
  name << "signalsmith_" << std::fixed << std::setprecision(2) << ratio << 'x';
  std::string value = name.str();
  std::replace(value.begin(), value.end(), '.', '_');
  return value + ".wav";
}

bool isTestArtifactPath(const std::filesystem::path &path) {
  for (const auto &part : path) {
    std::string segment = part.string();
    std::transform(segment.begin(), segment.end(), segment.begin(),
                   [](unsigned char value) {
                     return static_cast<char>(std::tolower(value));
                   });
    if (segment == "artifacts" || segment == "temp" || segment == "tmp" ||
        segment.find("test") != std::string::npos) {
      return true;
    }
  }
  return false;
}

} // namespace

int main(int argc, char **argv) {
  try {
    if (argc != 2) {
      std::cerr
          << "usage: homespotify_stretch_fixture_compare <artifacts-dir>\n";
      return 64;
    }
    const std::filesystem::path outputDirectory =
        std::filesystem::absolute(std::filesystem::path(argv[1]))
            .lexically_normal();
    if (!isTestArtifactPath(outputDirectory)) {
      throw std::invalid_argument("fixture artifacts are restricted to a "
                                  "test/temp/artifacts directory");
    }
    std::filesystem::create_directories(outputDirectory);

    HomeSpotifyStretchEngine availabilityProbe;
    if (!availabilityProbe.isAvailable()) {
      std::cerr << "NATIVE_LIBRARY_UNAVAILABLE: run "
                   "tool/vendor_signalsmith.ps1 first\n";
      return 78;
    }

    const std::vector<float> fixture = makeFixture();
    writeFloatWav(outputDirectory / "original.wav", fixture);
    const double inputPeak = peak(fixture);

    for (const double ratio : {0.70, 0.80, 1.20, 1.30}) {
      HomeSpotifyStretchEngine engine;
      engine.initialize(kSampleRate, kChannels);
      engine.setTempoRatio(ratio);
      const std::size_t inputFrames = fixture.size() / kChannels;
      const std::size_t capacity = engine.getRequiredOutputFrames(inputFrames);
      std::vector<float> output(capacity * kChannels);
      const auto start = std::chrono::steady_clock::now();
      const std::size_t processedFrames =
          engine.process(fixture.data(), fixture.size(), inputFrames,
                         output.data(), output.size(), capacity);
      output.resize(processedFrames * kChannels);
      const std::size_t flushCapacity = engine.getRequiredOutputFrames(0);
      std::vector<float> tail(flushCapacity * kChannels);
      const std::size_t tailFrames =
          engine.flush(tail.data(), tail.size(), flushCapacity);
      output.insert(output.end(), tail.begin(),
                    tail.begin() +
                        static_cast<std::ptrdiff_t>(tailFrames * kChannels));
      const std::size_t outputFrames = processedFrames + tailFrames;
      const auto stop = std::chrono::steady_clock::now();
      const double elapsedMs =
          std::chrono::duration<double, std::milli>(stop - start).count();
      const double sourceMs = inputFrames * 1000.0 / kSampleRate;
      const double realtimeFactor = elapsedMs > 0 ? sourceMs / elapsedMs : 0;

      writeFloatWav(outputDirectory / ratioFileName(ratio), output);
      std::cout << std::fixed << std::setprecision(4)
                << "{\"requestedRatio\":" << ratio
                << ",\"appliedRatio\":" << engine.getAppliedRatio()
                << ",\"sampleRate\":" << kSampleRate
                << ",\"channels\":" << kChannels
                << ",\"inputFrames\":" << inputFrames
                << ",\"outputFrames\":" << outputFrames
                << ",\"processingMs\":" << elapsedMs
                << ",\"realtimeFactor\":" << realtimeFactor
                << ",\"latencyFrames\":" << engine.getLatencyFrames()
                << ",\"inputPeak\":" << inputPeak
                << ",\"outputPeak\":" << peak(output)
                << ",\"outOfRangeSamples\":" << outOfRangeCount(output)
                << "}\n";
    }
    return 0;
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
