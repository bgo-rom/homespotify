#include "HomeSpotifyStretchEngine.h"

#include <algorithm>
#include <cmath>
#include <limits>
#include <sstream>
#include <stdexcept>
#include <utility>
#include <vector>

#if HOMESPOTIFY_STRETCH_HAS_SIGNALSMITH
#include "signalsmith-stretch.h"
#endif

namespace homespotify::stretch {
namespace {

constexpr int kMinimumSampleRate = 8000;
constexpr int kMaximumSampleRate = 192000;
constexpr std::size_t kMaximumFramesPerCall = 480000;
constexpr double kRatioTolerance = 0.000001;
constexpr double kRatioRampSeconds = 0.040;

std::size_t checkedSampleCount(std::size_t frames, int channels) {
  if (channels <= 0 || frames > std::numeric_limits<std::size_t>::max() /
                                    static_cast<std::size_t>(channels)) {
    throw std::invalid_argument("INVALID_ARGUMENT: PCM buffer size overflow");
  }
  return frames * static_cast<std::size_t>(channels);
}

std::string escapeJson(const std::string &value) {
  std::ostringstream escaped;
  for (const char character : value) {
    switch (character) {
    case '\\':
      escaped << "\\\\";
      break;
    case '"':
      escaped << "\\\"";
      break;
    case '\n':
      escaped << "\\n";
      break;
    case '\r':
      escaped << "\\r";
      break;
    case '\t':
      escaped << "\\t";
      break;
    default:
      escaped << character;
    }
  }
  return escaped.str();
}

} // namespace

class HomeSpotifyStretchEngine::Impl {
public:
#if HOMESPOTIFY_STRETCH_HAS_SIGNALSMITH
  signalsmith::stretch::SignalsmithStretch<float> stretcher;
#endif
};

HomeSpotifyStretchEngine::HomeSpotifyStretchEngine()
    : impl_(std::make_unique<Impl>()) {}

HomeSpotifyStretchEngine::~HomeSpotifyStretchEngine() { dispose(); }

void HomeSpotifyStretchEngine::initialize(int sampleRate, int channels) {
  std::lock_guard<std::mutex> lock(mutex_);
  ensureAvailableLocked();
  if (disposed_) {
    impl_ = std::make_unique<Impl>();
    disposed_ = false;
  }
  if (sampleRate < kMinimumSampleRate || sampleRate > kMaximumSampleRate) {
    throw std::invalid_argument(
        "UNSUPPORTED_FORMAT: sample rate must be between 8000 and 192000 Hz");
  }
  if (channels != 1 && channels != 2) {
    throw std::invalid_argument(
        "UNSUPPORTED_FORMAT: only mono and stereo PCM are supported");
  }

  sampleRate_ = sampleRate;
  channels_ = channels;
  targetRatio_ = 1.0;
  appliedRatio_ = 1.0;
  lastProcessRatio_ = 1.0;
  outputFrameRemainder_ = 0.0;
  rampFramesRemaining_ = 0;
  activeProfile_ = StretchProfile::transparent;
  requestedProfile_ = StretchProfile::transparent;
  profileChangePending_ = false;
  hasProcessedSinceReset_ = false;
  flushed_ = false;
  lastError_.clear();
  configureProfileLocked(activeProfile_);
  initialized_ = true;
}

void HomeSpotifyStretchEngine::setTempoRatio(double ratio) {
  std::lock_guard<std::mutex> lock(mutex_);
  ensureInitializedLocked();
  if (flushed_) {
    throw std::runtime_error(
        "INVALID_ARGUMENT: reset is required before processing after flush");
  }
  if (!std::isfinite(ratio) || ratio < kMinimumTempoRatio - kRatioTolerance ||
      ratio > kMaximumTempoRatio + kRatioTolerance) {
    throw std::invalid_argument(
        "INVALID_ARGUMENT: tempo ratio must be between 0.70 and 1.30");
  }

  ratio = std::clamp(ratio, kMinimumTempoRatio, kMaximumTempoRatio);
  if (std::abs(targetRatio_ - ratio) <= kRatioTolerance) {
    return;
  }

  targetRatio_ = ratio;
  requestedProfile_ = selectProfile(ratio);

  if (!hasProcessedSinceReset_) {
    configureProfileLocked(requestedProfile_);
    activeProfile_ = requestedProfile_;
    profileChangePending_ = false;
    appliedRatio_ = targetRatio_;
    lastProcessRatio_ = targetRatio_;
    outputFrameRemainder_ = 0.0;
    rampFramesRemaining_ = 0;
  } else {
    profileChangePending_ = requestedProfile_ != activeProfile_;
    rampFramesRemaining_ =
        std::max<std::int64_t>(1, static_cast<std::int64_t>(std::llround(
                                      sampleRate_ * kRatioRampSeconds)));
  }
}

std::size_t HomeSpotifyStretchEngine::process(
    const float *input, std::size_t inputSampleCount, std::size_t inputFrames,
    float *output, std::size_t outputSampleCapacity,
    std::size_t outputCapacityFrames) {
  std::lock_guard<std::mutex> lock(mutex_);
  ensureInitializedLocked();
  if (flushed_) {
    throw std::runtime_error(
        "INVALID_ARGUMENT: reset is required before processing after flush");
  }
  if (inputFrames == 0) {
    return 0;
  }
  if (inputFrames < 2) {
    throw std::invalid_argument(
        "INVALID_ARGUMENT: processPcm requires at least 2 input frames");
  }
  if (inputFrames > kMaximumFramesPerCall) {
    throw std::invalid_argument(
        "INVALID_ARGUMENT: processPcm is limited to 480000 frames per call");
  }
  if (input == nullptr || output == nullptr) {
    throw std::invalid_argument("INVALID_ARGUMENT: PCM buffer is null");
  }

  const std::size_t expectedInputSamples =
      checkedSampleCount(inputFrames, channels_);
  if (inputSampleCount != expectedInputSamples) {
    throw std::invalid_argument("INVALID_ARGUMENT: input sample count does not "
                                "match frames and channels");
  }
  if (outputSampleCapacity !=
      checkedSampleCount(outputCapacityFrames, channels_)) {
    throw std::invalid_argument("INVALID_ARGUMENT: output sample capacity does "
                                "not match frames and channels");
  }
  for (std::size_t index = 0; index < inputSampleCount; ++index) {
    if (!std::isfinite(input[index])) {
      throw std::invalid_argument(
          "INVALID_ARGUMENT: PCM input contains a non-finite sample");
    }
  }

  struct ProcessSegment {
    std::size_t inputOffset;
    std::size_t inputFrames;
    std::size_t outputOffset;
    std::size_t outputFrames;
    double processRatio;
    double endRatio;
    std::int64_t rampFramesRemaining;
    double outputFrameRemainder;
  };

  std::vector<ProcessSegment> segments;
  std::size_t remainingInput = inputFrames;
  std::size_t inputOffset = 0;
  std::size_t outputFrames = 0;
  double simulatedAppliedRatio = appliedRatio_;
  double simulatedRemainder = outputFrameRemainder_;
  std::int64_t simulatedRampFrames = rampFramesRemaining_;
  const std::size_t rampChunkFrames =
      static_cast<std::size_t>(std::max(64, sampleRate_ / 200));

  while (remainingInput > 0) {
    const std::size_t segmentInputFrames =
        simulatedRampFrames > 0 ? std::min(remainingInput, rampChunkFrames)
                                : remainingInput;
    const std::int64_t rampAdvance = std::min<std::int64_t>(
        static_cast<std::int64_t>(segmentInputFrames), simulatedRampFrames);
    double endRatio = simulatedAppliedRatio;
    if (simulatedRampFrames > 0) {
      const double progress = static_cast<double>(rampAdvance) /
                              static_cast<double>(simulatedRampFrames);
      endRatio = simulatedAppliedRatio +
                 (targetRatio_ - simulatedAppliedRatio) * progress;
    }
    const double processRatio = (simulatedAppliedRatio + endRatio) * 0.5;
    const double exactSegmentOutput =
        static_cast<double>(segmentInputFrames) / processRatio +
        simulatedRemainder;
    const std::size_t segmentOutputFrames =
        static_cast<std::size_t>(std::floor(exactSegmentOutput));
    if (segmentOutputFrames == 0 ||
        segmentOutputFrames >
            outputCapacityFrames -
                std::min(outputFrames, outputCapacityFrames)) {
      throw std::length_error("BUFFER_TOO_SMALL: output capacity is smaller "
                              "than the required frame count");
    }

    simulatedRemainder =
        exactSegmentOutput - static_cast<double>(segmentOutputFrames);
    simulatedAppliedRatio = endRatio;
    simulatedRampFrames -= rampAdvance;
    if (simulatedRampFrames <= 0) {
      simulatedRampFrames = 0;
      simulatedAppliedRatio = targetRatio_;
    }
    segments.push_back(ProcessSegment{
        inputOffset,
        segmentInputFrames,
        outputFrames,
        segmentOutputFrames,
        processRatio,
        simulatedAppliedRatio,
        simulatedRampFrames,
        simulatedRemainder,
    });
    inputOffset += segmentInputFrames;
    outputFrames += segmentOutputFrames;
    remainingInput -= segmentInputFrames;
  }

  if (outputFrames == 0 || outputFrames > outputCapacityFrames) {
    throw std::length_error("BUFFER_TOO_SMALL: output capacity is smaller than "
                            "the required frame count");
  }

  std::vector<std::vector<float>> inputPlanar(
      static_cast<std::size_t>(channels_), std::vector<float>(inputFrames));
  std::vector<std::vector<float>> outputPlanar(
      static_cast<std::size_t>(channels_), std::vector<float>(outputFrames));
  for (std::size_t frame = 0; frame < inputFrames; ++frame) {
    for (int channel = 0; channel < channels_; ++channel) {
      inputPlanar[static_cast<std::size_t>(channel)][frame] =
          input[frame * static_cast<std::size_t>(channels_) +
                static_cast<std::size_t>(channel)];
    }
  }

#if HOMESPOTIFY_STRETCH_HAS_SIGNALSMITH
  std::vector<float *> inputChannels(static_cast<std::size_t>(channels_));
  std::vector<float *> outputChannels(static_cast<std::size_t>(channels_));
  for (const ProcessSegment &segment : segments) {
    for (int channel = 0; channel < channels_; ++channel) {
      inputChannels[static_cast<std::size_t>(channel)] =
          inputPlanar[static_cast<std::size_t>(channel)].data() +
          segment.inputOffset;
      outputChannels[static_cast<std::size_t>(channel)] =
          outputPlanar[static_cast<std::size_t>(channel)].data() +
          segment.outputOffset;
    }
    impl_->stretcher.process(
        inputChannels.data(), static_cast<int>(segment.inputFrames),
        outputChannels.data(), static_cast<int>(segment.outputFrames));
  }
#else
  (void)inputPlanar;
  (void)outputPlanar;
  throw std::runtime_error(
      "NATIVE_LIBRARY_UNAVAILABLE: pinned Signalsmith headers are absent");
#endif

  for (std::size_t frame = 0; frame < outputFrames; ++frame) {
    for (int channel = 0; channel < channels_; ++channel) {
      output[frame * static_cast<std::size_t>(channels_) +
             static_cast<std::size_t>(channel)] =
          outputPlanar[static_cast<std::size_t>(channel)][frame];
    }
  }

  const ProcessSegment &finalSegment = segments.back();
  outputFrameRemainder_ = finalSegment.outputFrameRemainder;
  appliedRatio_ = finalSegment.endRatio;
  lastProcessRatio_ = finalSegment.processRatio;
  rampFramesRemaining_ = finalSegment.rampFramesRemaining;
  hasProcessedSinceReset_ = true;
  return outputFrames;
}

std::size_t HomeSpotifyStretchEngine::flush(float *output,
                                            std::size_t outputSampleCapacity,
                                            std::size_t outputCapacityFrames) {
  std::lock_guard<std::mutex> lock(mutex_);
  ensureInitializedLocked();
  if (!hasProcessedSinceReset_ || flushed_) {
    return 0;
  }
  if (output == nullptr) {
    throw std::invalid_argument(
        "INVALID_ARGUMENT: flush output buffer is null");
  }
  if (outputSampleCapacity !=
      checkedSampleCount(outputCapacityFrames, channels_)) {
    throw std::invalid_argument(
        "INVALID_ARGUMENT: flush capacity does not match frames and channels");
  }

#if HOMESPOTIFY_STRETCH_HAS_SIGNALSMITH
  const std::size_t inputTailFrames =
      static_cast<std::size_t>(std::max(0, impl_->stretcher.inputLatency()));
  const std::size_t stretchedInputTailFrames = static_cast<std::size_t>(
      std::ceil(static_cast<double>(inputTailFrames) / lastProcessRatio_));
  const std::size_t outputTailFrames =
      static_cast<std::size_t>(std::max(0, impl_->stretcher.outputLatency()));
  const std::size_t requiredFrames =
      stretchedInputTailFrames + outputTailFrames;
  if (outputCapacityFrames < requiredFrames) {
    throw std::length_error(
        "BUFFER_TOO_SMALL: flush capacity is smaller than output latency");
  }
  if (requiredFrames == 0) {
    return 0;
  }

  std::vector<std::vector<float>> outputPlanar(
      static_cast<std::size_t>(channels_), std::vector<float>(requiredFrames));
  std::vector<std::vector<float>> zeroInput(
      static_cast<std::size_t>(channels_), std::vector<float>(inputTailFrames));
  std::vector<float *> inputChannels(static_cast<std::size_t>(channels_));
  std::vector<float *> outputChannels(static_cast<std::size_t>(channels_));
  for (int channel = 0; channel < channels_; ++channel) {
    inputChannels[static_cast<std::size_t>(channel)] =
        zeroInput[static_cast<std::size_t>(channel)].data();
    outputChannels[static_cast<std::size_t>(channel)] =
        outputPlanar[static_cast<std::size_t>(channel)].data();
  }
  if (inputTailFrames > 0 && stretchedInputTailFrames > 0) {
    impl_->stretcher.process(
        inputChannels.data(), static_cast<int>(inputTailFrames),
        outputChannels.data(), static_cast<int>(stretchedInputTailFrames));
  }
  for (int channel = 0; channel < channels_; ++channel) {
    outputChannels[static_cast<std::size_t>(channel)] =
        outputPlanar[static_cast<std::size_t>(channel)].data() +
        stretchedInputTailFrames;
  }
  impl_->stretcher.flush(outputChannels.data(),
                         static_cast<int>(outputTailFrames), lastProcessRatio_);
  for (std::size_t frame = 0; frame < requiredFrames; ++frame) {
    for (int channel = 0; channel < channels_; ++channel) {
      output[frame * static_cast<std::size_t>(channels_) +
             static_cast<std::size_t>(channel)] =
          outputPlanar[static_cast<std::size_t>(channel)][frame];
    }
  }
  flushed_ = true;
  return requiredFrames;
#else
  throw std::runtime_error(
      "NATIVE_LIBRARY_UNAVAILABLE: pinned Signalsmith headers are absent");
#endif
}

void HomeSpotifyStretchEngine::reset() {
  std::lock_guard<std::mutex> lock(mutex_);
  ensureInitializedLocked();
#if HOMESPOTIFY_STRETCH_HAS_SIGNALSMITH
  impl_->stretcher.reset();
#endif
  targetRatio_ = 1.0;
  appliedRatio_ = 1.0;
  lastProcessRatio_ = 1.0;
  outputFrameRemainder_ = 0.0;
  rampFramesRemaining_ = 0;
  hasProcessedSinceReset_ = false;
  flushed_ = false;
  requestedProfile_ = StretchProfile::transparent;
  profileChangePending_ = activeProfile_ != requestedProfile_;
  applyPendingProfileLocked();
}

int HomeSpotifyStretchEngine::getLatencyFrames() const {
  std::lock_guard<std::mutex> lock(mutex_);
  ensureInitializedLocked();
#if HOMESPOTIFY_STRETCH_HAS_SIGNALSMITH
  return impl_->stretcher.inputLatency() + impl_->stretcher.outputLatency();
#else
  return 0;
#endif
}

std::size_t HomeSpotifyStretchEngine::getRequiredOutputFrames(
    std::size_t inputFrames) const {
  std::lock_guard<std::mutex> lock(mutex_);
  ensureInitializedLocked();
  if (inputFrames > kMaximumFramesPerCall) {
    throw std::invalid_argument(
        "INVALID_ARGUMENT: processPcm is limited to 480000 frames per call");
  }
  if (inputFrames == 0) {
    if (flushed_) {
      return 0;
    }
#if HOMESPOTIFY_STRETCH_HAS_SIGNALSMITH
    const double inputTail =
        static_cast<double>(std::max(0, impl_->stretcher.inputLatency()));
    const std::size_t stretchedInputTail =
        static_cast<std::size_t>(std::ceil(inputTail / lastProcessRatio_));
    return stretchedInputTail + static_cast<std::size_t>(std::max(
                                    0, impl_->stretcher.outputLatency()));
#else
    return 0;
#endif
  }
  const double conservativeRatio =
      std::max(kMinimumTempoRatio, std::min(appliedRatio_, targetRatio_));
  return static_cast<std::size_t>(
             std::ceil(static_cast<double>(inputFrames) / conservativeRatio)) +
         1;
}

double HomeSpotifyStretchEngine::getAppliedRatio() const {
  std::lock_guard<std::mutex> lock(mutex_);
  ensureInitializedLocked();
  return appliedRatio_;
}

std::string HomeSpotifyStretchEngine::getEngineInfo() const {
  std::lock_guard<std::mutex> lock(mutex_);
  const std::string effectiveLastError =
      !isAvailable() && lastError_.empty()
          ? "NATIVE_LIBRARY_UNAVAILABLE: pinned Signalsmith headers are absent"
          : lastError_;
  int inputLatency = 0;
  int outputLatency = 0;
  int blockSamples = 0;
  int intervalSamples = 0;
#if HOMESPOTIFY_STRETCH_HAS_SIGNALSMITH
  if (initialized_ && impl_) {
    inputLatency = impl_->stretcher.inputLatency();
    outputLatency = impl_->stretcher.outputLatency();
    blockSamples = impl_->stretcher.blockSamples();
    intervalSamples = impl_->stretcher.intervalSamples();
  }
#endif

  std::ostringstream json;
  json << '{' << "\"engineName\":\"HomeSpotify Stretch Engine\","
       << "\"foundation\":\"Signalsmith Stretch\","
       << "\"foundationVersion\":\"1.3.2\","
       << "\"engineVersion\":\"poc-0.1.0\","
       << "\"available\":" << (isAvailable() ? "true" : "false") << ','
       << "\"initialized\":" << (initialized_ ? "true" : "false") << ','
       << "\"sampleRate\":" << sampleRate_ << ','
       << "\"channels\":" << channels_ << ',' << "\"pitchRatio\":1.0,"
       << "\"targetRatio\":" << targetRatio_ << ','
       << "\"appliedRatio\":" << appliedRatio_ << ','
       << "\"lastProcessRatio\":" << lastProcessRatio_ << ','
       << "\"activeProfile\":\"" << profileName(activeProfile_) << "\","
       << "\"profile\":\"" << profileName(activeProfile_) << "\","
       << "\"requestedProfile\":\"" << profileName(requestedProfile_) << "\","
       << "\"pendingProfile\":";
  if (profileChangePending_) {
    json << "\"" << profileName(requestedProfile_) << "\"";
  } else {
    json << "null";
  }
  json << ',' << "\"profileChangePending\":"
       << (profileChangePending_ ? "true" : "false") << ','
       << "\"qualityMode\":\"POC_NOT_PRODUCTION_VALIDATED\","
       << "\"blockSamples\":" << blockSamples << ','
       << "\"intervalSamples\":" << intervalSamples << ','
       << "\"inputLatencyFrames\":" << inputLatency << ','
       << "\"outputLatencyFrames\":" << outputLatency << ','
       << "\"latencyFrames\":" << (inputLatency + outputLatency) << ','
       << "\"lastError\":\"" << escapeJson(effectiveLastError) << "\"" << '}';
  return json.str();
}

void HomeSpotifyStretchEngine::recordLastError(std::string message) noexcept {
  try {
    std::lock_guard<std::mutex> lock(mutex_);
    lastError_ = std::move(message);
  } catch (...) {
    return;
  }
}

void HomeSpotifyStretchEngine::dispose() noexcept {
  std::lock_guard<std::mutex> lock(mutex_);
  impl_.reset();
  initialized_ = false;
  disposed_ = true;
  sampleRate_ = 0;
  channels_ = 0;
  outputFrameRemainder_ = 0.0;
  rampFramesRemaining_ = 0;
  hasProcessedSinceReset_ = false;
  flushed_ = false;
}

bool HomeSpotifyStretchEngine::isAvailable() const noexcept {
#if HOMESPOTIFY_STRETCH_HAS_SIGNALSMITH
  return true;
#else
  return false;
#endif
}

bool HomeSpotifyStretchEngine::isInitialized() const noexcept {
  return initialized_;
}

int HomeSpotifyStretchEngine::channels() const noexcept { return channels_; }

int HomeSpotifyStretchEngine::sampleRate() const noexcept {
  return sampleRate_;
}

StretchProfile HomeSpotifyStretchEngine::selectProfile(double ratio) {
  if (!std::isfinite(ratio) || ratio < kMinimumTempoRatio - kRatioTolerance ||
      ratio > kMaximumTempoRatio + kRatioTolerance) {
    throw std::invalid_argument(
        "INVALID_ARGUMENT: tempo ratio must be between 0.70 and 1.30");
  }
  if (ratio >= 0.95 && ratio <= 1.05) {
    return StretchProfile::transparent;
  }
  if (ratio < 0.80 || ratio > 1.20) {
    return StretchProfile::extremeHq;
  }
  return StretchProfile::musical;
}

const char *
HomeSpotifyStretchEngine::profileName(StretchProfile profile) noexcept {
  switch (profile) {
  case StretchProfile::transparent:
    return "TRANSPARENT";
  case StretchProfile::musical:
    return "MUSICAL";
  case StretchProfile::extremeHq:
    return "EXTREME_HQ";
  }
  return "UNKNOWN";
}

void HomeSpotifyStretchEngine::ensureAvailableLocked() const {
  if (!isAvailable()) {
    throw std::runtime_error(
        "NATIVE_LIBRARY_UNAVAILABLE: pinned Signalsmith headers are absent");
  }
}

void HomeSpotifyStretchEngine::ensureInitializedLocked() const {
  ensureAvailableLocked();
  if (disposed_) {
    throw std::runtime_error("DISPOSED: native stretch engine was disposed");
  }
  if (!initialized_ || !impl_) {
    throw std::runtime_error(
        "NOT_INITIALIZED: initialize must be called before processing");
  }
}

void HomeSpotifyStretchEngine::configureProfileLocked(StretchProfile profile) {
#if HOMESPOTIFY_STRETCH_HAS_SIGNALSMITH
  ensureAvailableLocked();
  switch (profile) {
  case StretchProfile::transparent:
    impl_->stretcher.presetCheaper(channels_, sampleRate_, true);
    break;
  case StretchProfile::musical:
    impl_->stretcher.presetDefault(channels_, sampleRate_, true);
    break;
  case StretchProfile::extremeHq:
    impl_->stretcher.configure(
        channels_, static_cast<int>(std::lround(sampleRate_ * 0.160)),
        static_cast<int>(std::lround(sampleRate_ * 0.020)), true);
    break;
  }
  impl_->stretcher.setTransposeFactor(1.0f);
#else
  (void)profile;
#endif
}

void HomeSpotifyStretchEngine::applyPendingProfileLocked() {
  if (!profileChangePending_) {
    return;
  }
  configureProfileLocked(requestedProfile_);
  activeProfile_ = requestedProfile_;
  profileChangePending_ = false;
}

} // namespace homespotify::stretch
