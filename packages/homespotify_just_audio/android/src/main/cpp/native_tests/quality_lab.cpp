// HomeSpotify Stretch quality lab (host only, never shipped on device).
//
// Modes:
//   latch                       Prove/verify the live profile behaviour when the
//                               ratio crosses profile ranges mid-stream.
//   drift <ratio> [seconds]     Long-run ratio accuracy: cumulated frame error
//                               must stay bounded (fractional accumulator).
//   matrix <out-dir> [seconds]  Calibration matrix: candidate geometries x
//                               ratios on a synthetic musical fixture, with
//                               objective metrics as JSON lines.
//   render <in.wav> <out.wav> <ratio> <candidate>
//                               Stream a real WAV through the production engine
//                               path (PCM16 -> float -> engine -> PCM16) for
//                               listening comparisons. Candidates: transparent,
//                               musical, extreme_hq, cheaper_100_40,
//                               default_120_30, dense_120_20, long_160_20,
//                               short_90_22, nosplit_120_30.
//   transition <out-dir>        Ratio ramp audit (40/80/120/160 ms) with output
//                               continuity accounting and WAVs for listening.
//
// The synthetic fixture is generated in memory; WAV artifacts are only written
// into the caller-provided directory (kept out of the repository).

#include "HomeSpotifyStretchEngine.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <numeric>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

using homespotify::stretch::HomeSpotifyStretchEngine;
using homespotify::stretch::StretchProfile;

constexpr double kPi = 3.14159265358979323846;
constexpr int kFixtureSampleRate = 48000;
constexpr int kFixtureChannels = 2;
constexpr std::size_t kChunkFrames = 1024; // Typical Media3 PCM block size.

struct Candidate {
  std::string name;
  bool usesProfile;
  StretchProfile profile;
  double blockMs;
  double intervalMs;
  bool splitComputation;
};

const std::vector<Candidate> &allCandidates() {
  static const std::vector<Candidate> candidates = {
      {"transparent", true, StretchProfile::transparent, 0, 0, true},
      {"musical", true, StretchProfile::musical, 0, 0, true},
      {"extreme_hq", true, StretchProfile::extremeHq, 0, 0, true},
      {"cheaper_100_40", false, StretchProfile::transparent, 100, 40, true},
      {"default_120_30", false, StretchProfile::musical, 120, 30, true},
      {"dense_120_20", false, StretchProfile::musical, 120, 20, true},
      {"long_160_20", false, StretchProfile::extremeHq, 160, 20, true},
      {"short_90_22", false, StretchProfile::musical, 90, 22, true},
      {"nosplit_120_30", false, StretchProfile::musical, 120, 30, false},
  };
  return candidates;
}

const Candidate &findCandidate(const std::string &name) {
  for (const Candidate &candidate : allCandidates()) {
    if (candidate.name == name) {
      return candidate;
    }
  }
  throw std::invalid_argument("unknown candidate: " + name);
}

void applyCandidate(HomeSpotifyStretchEngine &engine,
                    const Candidate &candidate, int sampleRate, double ratio) {
  if (candidate.usesProfile) {
    engine.configure(candidate.profile, ratio);
  } else {
    engine.configureCustom(
        static_cast<int>(std::lround(sampleRate * candidate.blockMs / 1000.0)),
        static_cast<int>(
            std::lround(sampleRate * candidate.intervalMs / 1000.0)),
        candidate.splitComputation, ratio);
  }
}

// ---------------------------------------------------------------------------
// WAV I/O (PCM16 and float32, interleaved).

void writeU32(std::ofstream &out, std::uint32_t v) {
  const std::array<char, 4> b{static_cast<char>(v & 0xff),
                              static_cast<char>((v >> 8) & 0xff),
                              static_cast<char>((v >> 16) & 0xff),
                              static_cast<char>((v >> 24) & 0xff)};
  out.write(b.data(), 4);
}

void writeU16(std::ofstream &out, std::uint16_t v) {
  const std::array<char, 2> b{static_cast<char>(v & 0xff),
                              static_cast<char>((v >> 8) & 0xff)};
  out.write(b.data(), 2);
}

// PCM16 output uses the exact production conversion (round, saturate).
void writePcm16Wav(const std::filesystem::path &path,
                   const std::vector<float> &samples, int sampleRate,
                   int channels) {
  std::ofstream out(path, std::ios::binary | std::ios::trunc);
  if (!out) {
    throw std::runtime_error("cannot create " + path.string());
  }
  std::vector<std::int16_t> pcm(samples.size());
  for (std::size_t i = 0; i < samples.size(); ++i) {
    const float sample = samples[i];
    int value;
    if (sample >= 1.0f) {
      value = 32767;
    } else if (sample <= -1.0f) {
      value = -32768;
    } else {
      value = static_cast<int>(std::lround(sample * 32767.0f));
    }
    pcm[i] = static_cast<std::int16_t>(value);
  }
  const std::uint32_t dataBytes =
      static_cast<std::uint32_t>(pcm.size() * sizeof(std::int16_t));
  out.write("RIFF", 4);
  writeU32(out, 36 + dataBytes);
  out.write("WAVEfmt ", 8);
  writeU32(out, 16);
  writeU16(out, 1); // PCM16
  writeU16(out, static_cast<std::uint16_t>(channels));
  writeU32(out, static_cast<std::uint32_t>(sampleRate));
  writeU32(out, static_cast<std::uint32_t>(sampleRate * channels * 2));
  writeU16(out, static_cast<std::uint16_t>(channels * 2));
  writeU16(out, 16);
  out.write("data", 4);
  writeU32(out, dataBytes);
  out.write(reinterpret_cast<const char *>(pcm.data()), dataBytes);
}

struct WavData {
  int sampleRate = 0;
  int channels = 0;
  std::vector<float> samples; // interleaved, [-1, 1]
};

std::uint32_t readU32(std::ifstream &in) {
  std::array<unsigned char, 4> b{};
  in.read(reinterpret_cast<char *>(b.data()), 4);
  return static_cast<std::uint32_t>(b[0]) |
         (static_cast<std::uint32_t>(b[1]) << 8) |
         (static_cast<std::uint32_t>(b[2]) << 16) |
         (static_cast<std::uint32_t>(b[3]) << 24);
}

std::uint16_t readU16(std::ifstream &in) {
  std::array<unsigned char, 2> b{};
  in.read(reinterpret_cast<char *>(b.data()), 2);
  return static_cast<std::uint16_t>(b[0] |
                                    (static_cast<std::uint16_t>(b[1]) << 8));
}

WavData readWav(const std::filesystem::path &path) {
  std::ifstream in(path, std::ios::binary);
  if (!in) {
    throw std::runtime_error("cannot open " + path.string());
  }
  char riff[4];
  in.read(riff, 4);
  readU32(in); // riff size
  char wave[4];
  in.read(wave, 4);
  if (std::memcmp(riff, "RIFF", 4) != 0 || std::memcmp(wave, "WAVE", 4) != 0) {
    throw std::runtime_error("not a RIFF/WAVE file: " + path.string());
  }
  WavData wav;
  std::uint16_t format = 0;
  std::uint16_t bitsPerSample = 0;
  while (in && !in.eof()) {
    char chunkId[4];
    in.read(chunkId, 4);
    if (!in) {
      break;
    }
    const std::uint32_t chunkSize = readU32(in);
    if (std::memcmp(chunkId, "fmt ", 4) == 0) {
      format = readU16(in);
      wav.channels = readU16(in);
      wav.sampleRate = static_cast<int>(readU32(in));
      readU32(in); // byte rate
      readU16(in); // block align
      bitsPerSample = readU16(in);
      if (chunkSize > 16) {
        in.seekg(chunkSize - 16, std::ios::cur);
      }
    } else if (std::memcmp(chunkId, "data", 4) == 0) {
      std::vector<char> raw(chunkSize);
      in.read(raw.data(), chunkSize);
      if (format == 1 && bitsPerSample == 16) {
        const std::size_t count = chunkSize / 2;
        wav.samples.resize(count);
        const std::int16_t *pcm =
            reinterpret_cast<const std::int16_t *>(raw.data());
        for (std::size_t i = 0; i < count; ++i) {
          wav.samples[i] = static_cast<float>(pcm[i]) / 32768.0f;
        }
      } else if (format == 3 && bitsPerSample == 32) {
        const std::size_t count = chunkSize / 4;
        wav.samples.resize(count);
        std::memcpy(wav.samples.data(), raw.data(), count * sizeof(float));
      } else {
        throw std::runtime_error(
            "unsupported WAV encoding (need PCM16 or float32)");
      }
    } else {
      in.seekg(chunkSize + (chunkSize & 1u), std::ios::cur);
    }
  }
  if (wav.sampleRate <= 0 || wav.channels <= 0 || wav.samples.empty()) {
    throw std::runtime_error("incomplete WAV: " + path.string());
  }
  return wav;
}

// ---------------------------------------------------------------------------
// Synthetic musical fixture: kick + bass + vibrato "voice" + hats + pad.

std::vector<float> makeMusicFixture(std::size_t frames) {
  std::vector<float> fixture(frames * kFixtureChannels);
  std::uint32_t noiseState = 0x12345678;
  auto noise = [&noiseState]() {
    noiseState = noiseState * 1664525u + 1013904223u;
    return static_cast<float>(static_cast<std::int32_t>(noiseState)) /
           2147483648.0f;
  };
  for (std::size_t frame = 0; frame < frames; ++frame) {
    const double t = static_cast<double>(frame) / kFixtureSampleRate;

    // Kick every 500 ms: pitched 55 -> 45 Hz, 60 ms decay, 3 ms attack.
    const double kickPhase = std::fmod(t, 0.5);
    double kick = 0.0;
    if (kickPhase < 0.09) {
      const double env = std::exp(-kickPhase / 0.022) *
                         std::min(1.0, kickPhase / 0.003);
      const double freq = 45.0 + 10.0 * std::exp(-kickPhase / 0.02);
      kick = 0.55 * env * std::sin(2 * kPi * freq * kickPhase);
    }

    // Continuous bass E2 with two harmonics.
    const double bass = 0.16 * std::sin(2 * kPi * 82.41 * t) +
                        0.08 * std::sin(2 * kPi * 164.82 * t) +
                        0.04 * std::sin(2 * kPi * 247.2 * t);

    // Voice-ish tone: A3 with 5.5 Hz vibrato (+-20 cents) and 6 harmonics.
    const double vibrato = std::pow(2.0, 0.20 / 12.0 *
                                             std::sin(2 * kPi * 5.5 * t));
    const double f0 = 220.0 * vibrato;
    double voice = 0.0;
    for (int h = 1; h <= 6; ++h) {
      voice += (0.11 / h) * std::sin(2 * kPi * f0 * h * t);
    }

    // Hi-hat: 40 ms noise burst on off-beats, alternating pan.
    const double hatPhase = std::fmod(t + 0.25, 0.5);
    const bool hatLeft = std::fmod(t + 0.25, 1.0) < 0.5;
    double hat = 0.0;
    if (hatPhase < 0.04) {
      hat = 0.12 * std::exp(-hatPhase / 0.012) * noise();
    }

    // Static pad chord (E4/G#4/B4), low level, fully correlated.
    const double pad = 0.05 * (std::sin(2 * kPi * 329.6 * t) +
                               std::sin(2 * kPi * 415.3 * t) +
                               std::sin(2 * kPi * 493.9 * t));

    const double common = kick + bass + voice + pad;
    const double left = common + (hatLeft ? hat : 0.15 * hat);
    const double right = common + (hatLeft ? 0.15 * hat : hat);
    fixture[frame * kFixtureChannels] = static_cast<float>(left * 0.85);
    fixture[frame * kFixtureChannels + 1] = static_cast<float>(right * 0.85);
  }
  return fixture;
}

// ---------------------------------------------------------------------------
// Streaming helper mirroring the production Java sequencing.

struct StreamMetrics {
  std::size_t inputFrames = 0;
  std::size_t outputFrames = 0;
  std::vector<double> chunkMicros;
  std::size_t nanCount = 0;
  std::size_t outOfRange = 0;
  double outputPeak = 0;
};

StreamMetrics streamThroughEngine(HomeSpotifyStretchEngine &engine,
                                  const std::vector<float> &input,
                                  int channels, std::vector<float> *output,
                                  bool flushAtEnd = true) {
  StreamMetrics metrics;
  const std::size_t totalFrames = input.size() / channels;
  const std::size_t outputCapacityFrames =
      static_cast<std::size_t>(std::ceil(kChunkFrames / 0.70)) + 65536;
  std::vector<float> chunkOutput(outputCapacityFrames * channels);
  std::size_t consumed = 0;
  while (consumed < totalFrames) {
    const std::size_t frames = std::min(kChunkFrames, totalFrames - consumed);
    const float *chunk = input.data() + consumed * channels;
    const auto started = std::chrono::steady_clock::now();
    const std::size_t produced =
        engine.process(chunk, frames * channels, frames, chunkOutput.data(),
                       chunkOutput.size(), outputCapacityFrames);
    const auto elapsed = std::chrono::duration<double, std::micro>(
                             std::chrono::steady_clock::now() - started)
                             .count();
    metrics.chunkMicros.push_back(elapsed);
    consumed += frames;
    metrics.outputFrames += produced;
    if (output != nullptr) {
      output->insert(output->end(), chunkOutput.begin(),
                     chunkOutput.begin() +
                         static_cast<std::ptrdiff_t>(produced * channels));
    }
    for (std::size_t i = 0; i < produced * channels; ++i) {
      const float sample = chunkOutput[i];
      if (!std::isfinite(sample)) {
        ++metrics.nanCount;
      } else {
        metrics.outputPeak =
            std::max(metrics.outputPeak, std::abs(static_cast<double>(sample)));
        if (sample < -1.0f || sample > 1.0f) {
          ++metrics.outOfRange;
        }
      }
    }
    metrics.inputFrames = consumed;
  }
  // Flush the tail exactly like the production processor.
  if (flushAtEnd) {
    const std::size_t flushFrames = engine.getExpectedOutputFrames(0);
    if (flushFrames > 0) {
      std::vector<float> tail(flushFrames * channels);
      const auto started = std::chrono::steady_clock::now();
      const std::size_t flushed =
          engine.flush(tail.data(), tail.size(), flushFrames);
      const auto elapsed = std::chrono::duration<double, std::micro>(
                               std::chrono::steady_clock::now() - started)
                               .count();
      metrics.chunkMicros.push_back(elapsed);
      metrics.outputFrames += flushed;
      if (output != nullptr) {
        output->insert(output->end(), tail.begin(),
                       tail.begin() +
                           static_cast<std::ptrdiff_t>(flushed * channels));
      }
    }
  }
  return metrics;
}

double percentile(std::vector<double> values, double p) {
  if (values.empty()) {
    return 0;
  }
  std::sort(values.begin(), values.end());
  const double index = p * (values.size() - 1);
  const std::size_t low = static_cast<std::size_t>(std::floor(index));
  const std::size_t high = std::min(values.size() - 1, low + 1);
  const double frac = index - low;
  return values[low] * (1 - frac) + values[high] * frac;
}

// ---------------------------------------------------------------------------
// Objective signal metrics.

std::vector<float> monoMix(const std::vector<float> &samples, int channels) {
  std::vector<float> mono(samples.size() / channels);
  for (std::size_t f = 0; f < mono.size(); ++f) {
    float sum = 0;
    for (int c = 0; c < channels; ++c) {
      sum += samples[f * channels + c];
    }
    mono[f] = sum / channels;
  }
  return mono;
}

// Average 50%-of-peak envelope width (ms) around expected kick instants.
double onsetWidthMs(const std::vector<float> &mono, int sampleRate,
                    double ratio, double fixtureSeconds) {
  const double binMs = 1.0;
  const std::size_t binFrames =
      static_cast<std::size_t>(sampleRate * binMs / 1000.0);
  std::vector<double> widths;
  for (double tk = 1.0; tk + 1.0 < fixtureSeconds; tk += 0.5) {
    const double outCenter = tk / ratio;
    const std::size_t centerFrame =
        static_cast<std::size_t>(outCenter * sampleRate);
    const std::size_t halfWindow =
        static_cast<std::size_t>(0.070 * sampleRate);
    if (centerFrame < halfWindow ||
        centerFrame + halfWindow >= mono.size()) {
      continue;
    }
    // 1 ms envelope bins over +-70 ms.
    std::vector<double> env;
    for (std::size_t start = centerFrame - halfWindow;
         start + binFrames <= centerFrame + halfWindow; start += binFrames) {
      double peak = 0;
      for (std::size_t i = start; i < start + binFrames; ++i) {
        peak = std::max(peak, std::abs(static_cast<double>(mono[i])));
      }
      env.push_back(peak);
    }
    const double floorLevel =
        *std::min_element(env.begin(), env.end());
    double peak = 0;
    std::size_t peakIndex = 0;
    for (std::size_t i = 0; i < env.size(); ++i) {
      if (env[i] > peak) {
        peak = env[i];
        peakIndex = i;
      }
    }
    const double net = peak - floorLevel;
    if (net <= 0.05) {
      continue; // No clear transient found; skip rather than fake a value.
    }
    const double threshold = floorLevel + net * 0.5;
    std::size_t left = peakIndex;
    while (left > 0 && env[left - 1] >= threshold) {
      --left;
    }
    std::size_t right = peakIndex;
    while (right + 1 < env.size() && env[right + 1] >= threshold) {
      ++right;
    }
    widths.push_back((right - left + 1) * binMs);
  }
  if (widths.empty()) {
    return -1;
  }
  return std::accumulate(widths.begin(), widths.end(), 0.0) / widths.size();
}

// Goertzel magnitude of one frequency over a window.
double goertzel(const std::vector<float> &mono, std::size_t start,
                std::size_t length, double frequency, int sampleRate) {
  const double k = std::round(length * frequency / sampleRate);
  const double omega = 2 * kPi * k / length;
  const double coeff = 2 * std::cos(omega);
  double s0 = 0, s1 = 0, s2 = 0;
  for (std::size_t i = start; i < start + length && i < mono.size(); ++i) {
    s0 = mono[i] + coeff * s1 - s2;
    s2 = s1;
    s1 = s0;
  }
  return std::sqrt(std::max(0.0, s1 * s1 + s2 * s2 - coeff * s1 * s2));
}

// Coefficient of variation of the 82.41 Hz bass partial over 100 ms hops.
double bassWobble(const std::vector<float> &mono, int sampleRate) {
  const std::size_t window = static_cast<std::size_t>(0.100 * sampleRate);
  const std::size_t hop = window / 2;
  std::vector<double> magnitudes;
  for (std::size_t start = window;
       start + 2 * window < mono.size(); start += hop) {
    magnitudes.push_back(goertzel(mono, start, window, 82.41, sampleRate));
  }
  if (magnitudes.size() < 8) {
    return -1;
  }
  const double mean =
      std::accumulate(magnitudes.begin(), magnitudes.end(), 0.0) /
      magnitudes.size();
  double variance = 0;
  for (const double m : magnitudes) {
    variance += (m - mean) * (m - mean);
  }
  variance /= magnitudes.size();
  return mean > 0 ? std::sqrt(variance) / mean : -1;
}

double stereoCorrelation(const std::vector<float> &samples, int channels) {
  if (channels != 2) {
    return 1;
  }
  double sumL = 0, sumR = 0, sumLL = 0, sumRR = 0, sumLR = 0;
  const std::size_t frames = samples.size() / 2;
  for (std::size_t f = 0; f < frames; ++f) {
    const double l = samples[f * 2];
    const double r = samples[f * 2 + 1];
    sumL += l;
    sumR += r;
    sumLL += l * l;
    sumRR += r * r;
    sumLR += l * r;
  }
  const double n = static_cast<double>(frames);
  const double cov = sumLR / n - (sumL / n) * (sumR / n);
  const double varL = sumLL / n - (sumL / n) * (sumL / n);
  const double varR = sumRR / n - (sumR / n) * (sumR / n);
  if (varL <= 0 || varR <= 0) {
    return 0;
  }
  return cov / std::sqrt(varL * varR);
}

// ---------------------------------------------------------------------------
// Modes.

int runLatch() {
  HomeSpotifyStretchEngine engine;
  engine.initialize(kFixtureSampleRate, kFixtureChannels);
  // Java flush() boundary for a slider leaving 1.00x: reset + setRatio(1.04).
  engine.setTempoRatio(1.04, 0);
  const std::vector<float> fixture =
      makeMusicFixture(2 * kFixtureSampleRate);
  streamThroughEngine(engine, fixture, kFixtureChannels, nullptr,
                      /*flushAtEnd=*/false);
  std::cout << "after ratio 1.04 (stream started):\n  "
            << engine.getMetricsJson() << "\n";
  // Live slider move to 1.30x: no Media3 flush boundary, 40 ms ramp.
  engine.setTempoRatio(1.30, kFixtureSampleRate * 40 / 1000);
  const std::vector<float> more = makeMusicFixture(2 * kFixtureSampleRate);
  streamThroughEngine(engine, more, kFixtureChannels, nullptr,
                      /*flushAtEnd=*/false);
  std::cout << "after live change to 1.30 (no flush boundary):\n  "
            << engine.getMetricsJson() << "\n";
  return 0;
}

int runDrift(double ratio, double seconds) {
  HomeSpotifyStretchEngine engine;
  engine.initialize(kFixtureSampleRate, kFixtureChannels);
  engine.setTempoRatio(ratio, 0);
  const std::size_t totalFrames =
      static_cast<std::size_t>(seconds * kFixtureSampleRate);
  const std::vector<float> fixture = makeMusicFixture(totalFrames);
  const int latencyFrames = engine.getLatencyFrames();

  const std::size_t capacity =
      static_cast<std::size_t>(std::ceil(kChunkFrames / 0.70)) + 65536;
  std::vector<float> out(capacity * kFixtureChannels);
  std::size_t consumed = 0;
  std::size_t producedTotal = 0;
  double maxAbsError = 0;
  std::size_t nextReport = kFixtureSampleRate * 10;
  std::cout << "{\"mode\":\"drift\",\"ratio\":" << ratio
            << ",\"latencyFrames\":" << latencyFrames << "}\n";
  while (consumed < totalFrames) {
    const std::size_t n = std::min(kChunkFrames, totalFrames - consumed);
    const std::size_t produced = engine.process(
        fixture.data() + consumed * kFixtureChannels, n * kFixtureChannels, n,
        out.data(), out.size(), capacity);
    consumed += n;
    producedTotal += produced;
    // Steady-state expectation: produced ~= (consumed - latencyShare)/ratio.
    const double expected = static_cast<double>(consumed) / ratio;
    const double error =
        expected - static_cast<double>(producedTotal); // includes DSP latency
    maxAbsError = std::max(maxAbsError,
                           std::abs(error - latencyFrames / ratio));
    if (consumed >= nextReport) {
      std::cout << "{\"consumed\":" << consumed
                << ",\"produced\":" << producedTotal
                << ",\"steadyErrorFrames\":" << std::fixed
                << std::setprecision(3) << (error - latencyFrames / ratio)
                << "}\n";
      nextReport += kFixtureSampleRate * 10;
    }
  }
  const std::size_t flushFrames = engine.getExpectedOutputFrames(0);
  std::vector<float> tail(flushFrames * kFixtureChannels);
  producedTotal += engine.flush(tail.data(), tail.size(), flushFrames);
  const long long expectedTotal =
      std::llround(static_cast<double>(totalFrames) / ratio);
  const long long finalError =
      static_cast<long long>(producedTotal) - expectedTotal;
  std::cout << "{\"totalInput\":" << totalFrames
            << ",\"totalOutput\":" << producedTotal
            << ",\"expectedOutput\":" << expectedTotal
            << ",\"finalErrorFrames\":" << finalError
            << ",\"maxSteadyErrorFrames\":" << std::fixed
            << std::setprecision(3) << maxAbsError << "}\n";
  return std::llabs(finalError) <= 1 ? 0 : 1;
}

int runMatrix(const std::filesystem::path &outDir, double seconds) {
  std::filesystem::create_directories(outDir);
  const std::size_t frames =
      static_cast<std::size_t>(seconds * kFixtureSampleRate);
  const std::vector<float> fixture = makeMusicFixture(frames);
  const std::vector<float> fixtureMono = monoMix(fixture, kFixtureChannels);
  const double inputOnset =
      onsetWidthMs(fixtureMono, kFixtureSampleRate, 1.0, seconds);
  const double inputWobble = bassWobble(fixtureMono, kFixtureSampleRate);
  const double inputCorr = stereoCorrelation(fixture, kFixtureChannels);
  std::cout << "{\"fixture\":{\"seconds\":" << seconds
            << ",\"onsetWidthMs\":" << inputOnset
            << ",\"bassWobble\":" << inputWobble
            << ",\"stereoCorr\":" << inputCorr << "}}\n";

  const std::array<double, 8> ratios{0.70, 0.80, 0.90, 0.95,
                                     1.05, 1.10, 1.20, 1.30};
  for (const Candidate &candidate : allCandidates()) {
    if (candidate.usesProfile) {
      continue; // Profiles duplicate explicit geometries below.
    }
    for (const double ratio : ratios) {
      HomeSpotifyStretchEngine engine;
      engine.initialize(kFixtureSampleRate, kFixtureChannels);
      applyCandidate(engine, candidate, kFixtureSampleRate, ratio);
      std::vector<float> output;
      output.reserve(static_cast<std::size_t>(frames / ratio) + 65536);
      StreamMetrics metrics =
          streamThroughEngine(engine, fixture, kFixtureChannels, &output);
      const std::vector<float> outMono = monoMix(output, kFixtureChannels);
      const double audioSeconds =
          static_cast<double>(metrics.inputFrames) / kFixtureSampleRate;
      const double dspSeconds =
          std::accumulate(metrics.chunkMicros.begin(),
                          metrics.chunkMicros.end(), 0.0) /
          1e6;
      const double avgRatio =
          static_cast<double>(metrics.inputFrames) /
          std::max<std::size_t>(1, metrics.outputFrames);
      std::cout << "{\"candidate\":\"" << candidate.name << "\",\"ratio\":"
                << std::fixed << std::setprecision(2) << ratio
                << std::setprecision(6) << ",\"avgRatio\":" << avgRatio
                << ",\"ratioErrorPpm\":"
                << (avgRatio / ratio - 1.0) * 1e6
                << ",\"latencyFrames\":" << engine.getLatencyFrames()
                << ",\"latencyMs\":" << std::setprecision(1)
                << engine.getLatencyFrames() * 1000.0 / kFixtureSampleRate
                << ",\"dspAvgMicrosPerChunk\":" << std::setprecision(1)
                << (metrics.chunkMicros.empty()
                        ? 0.0
                        : std::accumulate(metrics.chunkMicros.begin(),
                                          metrics.chunkMicros.end(), 0.0) /
                              metrics.chunkMicros.size())
                << ",\"dspP95Micros\":" << percentile(metrics.chunkMicros, 0.95)
                << ",\"dspMaxMicros\":" << percentile(metrics.chunkMicros, 1.0)
                << ",\"realtimeFactor\":" << std::setprecision(1)
                << (dspSeconds > 0 ? audioSeconds / dspSeconds : 0)
                << ",\"outputPeak\":" << std::setprecision(4)
                << metrics.outputPeak << ",\"nan\":" << metrics.nanCount
                << ",\"outOfRange\":" << metrics.outOfRange
                << ",\"onsetWidthMs\":" << std::setprecision(2)
                << onsetWidthMs(outMono, kFixtureSampleRate, ratio, seconds)
                << ",\"bassWobble\":" << std::setprecision(4)
                << bassWobble(outMono, kFixtureSampleRate)
                << ",\"stereoCorr\":" << std::setprecision(4)
                << stereoCorrelation(output, kFixtureChannels) << "}\n";
      if (ratio == 0.80 || ratio == 1.20 || ratio == 1.30) {
        std::ostringstream name;
        name << candidate.name << "_" << std::fixed << std::setprecision(2)
             << ratio << "x.wav";
        std::string file = name.str();
        std::replace(file.begin(), file.end(), '.', '_');
        file.replace(file.rfind("_wav"), 4, ".wav");
        writePcm16Wav(outDir / file, output, kFixtureSampleRate,
                      kFixtureChannels);
      }
    }
  }
  writePcm16Wav(outDir / "fixture_original.wav", fixture, kFixtureSampleRate,
                kFixtureChannels);
  return 0;
}

int runRender(const std::filesystem::path &inPath,
              const std::filesystem::path &outPath, double ratio,
              const std::string &candidateName) {
  const Candidate &candidate = findCandidate(candidateName);
  WavData wav = readWav(inPath);
  if (wav.channels > 2) {
    throw std::runtime_error("render supports mono/stereo only");
  }
  HomeSpotifyStretchEngine engine;
  engine.initialize(wav.sampleRate, wav.channels);
  applyCandidate(engine, candidate, wav.sampleRate, ratio);
  std::vector<float> output;
  StreamMetrics metrics =
      streamThroughEngine(engine, wav.samples, wav.channels, &output);
  writePcm16Wav(outPath, output, wav.sampleRate, wav.channels);
  const double audioSeconds =
      static_cast<double>(metrics.inputFrames) / wav.sampleRate;
  const double dspSeconds =
      std::accumulate(metrics.chunkMicros.begin(), metrics.chunkMicros.end(),
                      0.0) /
      1e6;
  std::cout << "{\"render\":\"" << outPath.string() << "\",\"candidate\":\""
            << candidate.name << "\",\"ratio\":" << ratio
            << ",\"inputFrames\":" << metrics.inputFrames
            << ",\"outputFrames\":" << metrics.outputFrames
            << ",\"latencyMs\":"
            << engine.getLatencyFrames() * 1000.0 / wav.sampleRate
            << ",\"realtimeFactor\":"
            << (dspSeconds > 0 ? audioSeconds / dspSeconds : 0)
            << ",\"outputPeak\":" << metrics.outputPeak
            << ",\"nan\":" << metrics.nanCount << ",\"outOfRange\":"
            << metrics.outOfRange << "}\n";
  return 0;
}

int runTransition(const std::filesystem::path &outDir) {
  std::filesystem::create_directories(outDir);
  const std::array<int, 4> transitionsMs{40, 80, 120, 160};
  const std::size_t frames = 14 * kFixtureSampleRate;
  const std::vector<float> fixture = makeMusicFixture(frames);
  for (const int transitionMs : transitionsMs) {
    HomeSpotifyStretchEngine engine;
    engine.initialize(kFixtureSampleRate, kFixtureChannels);
    engine.setTempoRatio(1.00, 0);
    const std::size_t capacity =
        static_cast<std::size_t>(std::ceil(kChunkFrames / 0.70)) + 65536;
    std::vector<float> chunkOut(capacity * kFixtureChannels);
    std::vector<float> output;
    std::size_t consumed = 0;
    bool switched = false;
    bool switchedBack = false;
    while (consumed < frames) {
      const double t = static_cast<double>(consumed) / kFixtureSampleRate;
      if (!switched && t >= 4.0) {
        engine.setTempoRatio(
            1.30, kFixtureSampleRate * transitionMs / 1000);
        switched = true;
      }
      if (!switchedBack && t >= 9.0) {
        engine.setTempoRatio(
            0.70, kFixtureSampleRate * transitionMs / 1000);
        switchedBack = true;
      }
      const std::size_t n = std::min(kChunkFrames, frames - consumed);
      const std::size_t produced = engine.process(
          fixture.data() + consumed * kFixtureChannels, n * kFixtureChannels,
          n, chunkOut.data(), chunkOut.size(), capacity);
      output.insert(output.end(), chunkOut.begin(),
                    chunkOut.begin() +
                        static_cast<std::ptrdiff_t>(produced *
                                                    kFixtureChannels));
      consumed += n;
    }
    const std::size_t flushFrames = engine.getExpectedOutputFrames(0);
    std::vector<float> tail(flushFrames * kFixtureChannels);
    const std::size_t flushed =
        engine.flush(tail.data(), tail.size(), flushFrames);
    output.insert(output.end(), tail.begin(),
                  tail.begin() +
                      static_cast<std::ptrdiff_t>(flushed * kFixtureChannels));
    std::ostringstream name;
    name << "transition_" << transitionMs << "ms.wav";
    writePcm16Wav(outDir / name.str(), output, kFixtureSampleRate,
                  kFixtureChannels);
    std::cout << "{\"transitionMs\":" << transitionMs
              << ",\"outputFrames\":" << output.size() / kFixtureChannels
              << ",\"file\":\"" << name.str() << "\"}\n";
  }
  return 0;
}

} // namespace

int main(int argc, char **argv) {
  try {
    if (argc < 2) {
      std::cerr << "usage: quality_lab "
                   "latch|drift|matrix|render|transition ...\n";
      return 64;
    }
    const std::string mode = argv[1];
    if (mode == "latch") {
      return runLatch();
    }
    if (mode == "drift") {
      if (argc < 3) {
        std::cerr << "usage: quality_lab drift <ratio> [seconds]\n";
        return 64;
      }
      return runDrift(std::stod(argv[2]),
                      argc > 3 ? std::stod(argv[3]) : 90.0);
    }
    if (mode == "matrix") {
      if (argc < 3) {
        std::cerr << "usage: quality_lab matrix <out-dir> [seconds]\n";
        return 64;
      }
      return runMatrix(argv[2], argc > 3 ? std::stod(argv[3]) : 30.0);
    }
    if (mode == "render") {
      if (argc != 6) {
        std::cerr << "usage: quality_lab render <in.wav> <out.wav> <ratio> "
                     "<candidate>\n";
        return 64;
      }
      return runRender(argv[2], argv[3], std::stod(argv[4]), argv[5]);
    }
    if (mode == "transition") {
      if (argc < 3) {
        std::cerr << "usage: quality_lab transition <out-dir>\n";
        return 64;
      }
      return runTransition(argv[2]);
    }
    std::cerr << "unknown mode: " << mode << "\n";
    return 64;
  } catch (const std::exception &error) {
    std::cerr << error.what() << "\n";
    return 1;
  }
}
