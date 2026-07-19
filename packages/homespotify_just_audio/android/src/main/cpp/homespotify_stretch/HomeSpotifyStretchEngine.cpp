#include "HomeSpotifyStretchEngine.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <limits>
#include <sstream>
#include <stdexcept>
#include <utility>

#if HOMESPOTIFY_STRETCH_HAS_SIGNALSMITH
#include "signalsmith-stretch.h"
#endif

namespace homespotify::stretch {
namespace {

constexpr int kMinimumSampleRate = 8000;
constexpr int kMaximumSampleRate = 192000;
constexpr double kRatioTolerance = 0.000001;
constexpr std::uint64_t kMaximumTransitionSeconds = 2;

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
  ensureAvailable();
  if (sampleRate < kMinimumSampleRate || sampleRate > kMaximumSampleRate) {
    throw std::invalid_argument(
        "UNSUPPORTED_FORMAT: sample rate must be between 8000 and 192000 Hz");
  }
  if (channels != 1 && channels != 2) {
    throw std::invalid_argument(
        "UNSUPPORTED_FORMAT: only mono and stereo PCM are supported");
  }
  if (disposed_ || !impl_) {
    impl_ = std::make_unique<Impl>();
    disposed_ = false;
  }

  sampleRate_ = sampleRate;
  channels_ = channels;
  // One production configuration for the whole 0.70x-1.30x range: a live
  // ratio change can never be paired with a Signalsmith reconfiguration
  // (that resets the STFT), so any ratio-driven profile switching would
  // leave the stream on the profile of the FIRST non-unit ratio. The
  // override below is the dev/A-B escape hatch, applied at reset boundaries.
  activeProfile_ = effectiveProfile(1.0);
  requestedProfile_ = activeProfile_;
  profileChangePending_ = false;
  configureProfile(activeProfile_);
  allocateRealtimeBuffers();

  targetRatio_ = 1.0;
  appliedRatio_ = 1.0;
  lastProcessRatio_ = 1.0;
  outputFrameRemainder_ = 0.0;
  rampFramesRemaining_ = 0;
  hasProcessedSinceReset_ = false;
  flushed_ = false;
  outputFramesProduced_ = 0;
  initialized_ = true;
  prepareStartup();

  processCount_.store(0, std::memory_order_relaxed);
  totalProcessNanoseconds_.store(0, std::memory_order_relaxed);
  maximumProcessNanoseconds_.store(0, std::memory_order_relaxed);
  lastProcessNanoseconds_.store(0, std::memory_order_relaxed);
  metricSampleRate_.store(sampleRate_, std::memory_order_relaxed);
  metricChannels_.store(channels_, std::memory_order_relaxed);
  metricActiveProfile_.store(static_cast<int>(activeProfile_),
                             std::memory_order_relaxed);
  metricRequestedProfile_.store(static_cast<int>(requestedProfile_),
                                std::memory_order_relaxed);
  metricTargetRatio_.store(1.0, std::memory_order_relaxed);
  metricAppliedRatio_.store(1.0, std::memory_order_relaxed);
  metricProfilePending_.store(false, std::memory_order_relaxed);
  metricInitialized_.store(true, std::memory_order_release);
  clearLastError();
}

void HomeSpotifyStretchEngine::configure(StretchProfile profile,
                                         double tempoRatio) {
  ensureInitialized();
  (void)selectProfile(tempoRatio);
  if (hasProcessedSinceReset_) {
    throw std::runtime_error(
        "INVALID_STATE: configure requires reset before streamed PCM");
  }

  configureProfile(profile);
  activeProfile_ = profile;
  requestedProfile_ = profile;
  profileChangePending_ = false;
  targetRatio_ = std::clamp(tempoRatio, kMinimumTempoRatio,
                            kMaximumTempoRatio);
  appliedRatio_ = targetRatio_;
  lastProcessRatio_ = targetRatio_;
  outputFrameRemainder_ = 0.0;
  rampFramesRemaining_ = 0;
  flushed_ = false;
  outputFramesProduced_ = 0;
  prepareStartup();

  metricActiveProfile_.store(static_cast<int>(activeProfile_),
                             std::memory_order_relaxed);
  metricRequestedProfile_.store(static_cast<int>(requestedProfile_),
                                std::memory_order_relaxed);
  metricTargetRatio_.store(targetRatio_, std::memory_order_relaxed);
  metricAppliedRatio_.store(appliedRatio_, std::memory_order_relaxed);
  metricProfilePending_.store(false, std::memory_order_relaxed);
}

void HomeSpotifyStretchEngine::configureCustom(int blockSamples,
                                               int intervalSamples,
                                               bool splitComputation,
                                               double tempoRatio) {
  ensureInitialized();
  if (hasProcessedSinceReset_) {
    throw std::runtime_error(
        "INVALID_STATE: configureCustom requires reset before streamed PCM");
  }
  const int minimumBlock = std::max(2, sampleRate_ / 100);       // 10 ms
  const int maximumBlock = (sampleRate_ * 32) / 100;             // 320 ms
  const int minimumInterval = std::max(1, sampleRate_ / 200);    // 5 ms
  if (blockSamples < minimumBlock || blockSamples > maximumBlock ||
      intervalSamples < minimumInterval ||
      intervalSamples > blockSamples / 2) {
    throw std::invalid_argument(
        "INVALID_ARGUMENT: custom stretch geometry is out of range");
  }

#if HOMESPOTIFY_STRETCH_HAS_SIGNALSMITH
  impl_->stretcher.configure(channels_, blockSamples, intervalSamples,
                             splitComputation);
  impl_->stretcher.setTransposeFactor(1.0f);
  metricLatencyFrames_.store(
      impl_->stretcher.inputLatency() + impl_->stretcher.outputLatency(),
      std::memory_order_relaxed);
#endif
  // A custom geometry intentionally has no matching profile enum value; the
  // metrics keep reporting the last profile-driven state.
  targetRatio_ = std::clamp(tempoRatio, kMinimumTempoRatio,
                            kMaximumTempoRatio);
  appliedRatio_ = targetRatio_;
  lastProcessRatio_ = targetRatio_;
  outputFrameRemainder_ = 0.0;
  rampFramesRemaining_ = 0;
  profileChangePending_ = false;
  flushed_ = false;
  outputFramesProduced_ = 0;
  prepareStartup();

  metricTargetRatio_.store(targetRatio_, std::memory_order_relaxed);
  metricAppliedRatio_.store(appliedRatio_, std::memory_order_relaxed);
  metricProfilePending_.store(false, std::memory_order_relaxed);
}

void HomeSpotifyStretchEngine::setTempoRatio(
    double ratio, std::uint32_t transitionFrames) {
  ensureInitialized();
  if (flushed_) {
    throw std::runtime_error(
        "INVALID_STATE: reset is required after end of stream");
  }

  const StretchProfile requestedProfile = effectiveProfile(ratio);
  ratio = std::clamp(ratio, kMinimumTempoRatio, kMaximumTempoRatio);
  if (transitionFrames >
      static_cast<std::uint64_t>(sampleRate_) * kMaximumTransitionSeconds) {
    throw std::invalid_argument(
        "INVALID_ARGUMENT: tempo transition cannot exceed two seconds");
  }

  requestedProfile_ = requestedProfile;
  if (!hasProcessedSinceReset_ && requestedProfile_ != activeProfile_) {
    configureProfile(requestedProfile_);
    activeProfile_ = requestedProfile_;
    profileChangePending_ = false;
  } else {
    // Signalsmith configuration changes reset its STFT. During a live stream,
    // keep the current configuration until Media3 reaches a reset boundary;
    // the ratio itself still ramps without dropping buffered PCM.
    profileChangePending_ = requestedProfile_ != activeProfile_;
  }

  targetRatio_ = ratio;
  if (transitionFrames == 0 || !hasProcessedSinceReset_) {
    appliedRatio_ = targetRatio_;
    lastProcessRatio_ = targetRatio_;
    rampFramesRemaining_ = 0;
  } else {
    rampFramesRemaining_ = transitionFrames;
  }
  if (!hasProcessedSinceReset_) {
    prepareStartup();
  }

  metricActiveProfile_.store(static_cast<int>(activeProfile_),
                             std::memory_order_relaxed);
  metricRequestedProfile_.store(static_cast<int>(requestedProfile_),
                                std::memory_order_relaxed);
  metricTargetRatio_.store(targetRatio_, std::memory_order_relaxed);
  metricAppliedRatio_.store(appliedRatio_, std::memory_order_relaxed);
  metricProfilePending_.store(profileChangePending_,
                              std::memory_order_relaxed);
}

std::size_t HomeSpotifyStretchEngine::process(
    const float *input, std::size_t inputSampleCount, std::size_t inputFrames,
    float *output, std::size_t outputSampleCapacity,
    std::size_t outputCapacityFrames) {
  ensureInitialized();
  if (flushed_) {
    throw std::runtime_error(
        "INVALID_STATE: reset is required after end of stream");
  }
  if (inputFrames == 0) {
    return 0;
  }
  if (inputFrames < 2 || inputFrames > kMaximumInputFramesPerCall) {
    throw std::invalid_argument(
        "INVALID_ARGUMENT: process requires 2 to 65536 input frames");
  }
  if (input == nullptr || output == nullptr) {
    throw std::invalid_argument("INVALID_ARGUMENT: PCM buffer is null");
  }

  const std::size_t expectedInputSamples =
      checkedSampleCount(inputFrames, channels_);
  if (inputSampleCount != expectedInputSamples) {
    throw std::invalid_argument(
        "INVALID_ARGUMENT: input capacity does not match frames and channels");
  }
  if (outputSampleCapacity !=
      checkedSampleCount(outputCapacityFrames, channels_)) {
    throw std::invalid_argument(
        "INVALID_ARGUMENT: output capacity does not match frames and channels");
  }
  for (std::size_t index = 0; index < inputSampleCount; ++index) {
    if (!std::isfinite(input[index])) {
      throw std::invalid_argument(
          "INVALID_ARGUMENT: PCM input contains a non-finite sample");
    }
  }

  const std::size_t startupFramesNeeded =
      startupPrimed_ ? 0 : startupRequiredFrames_ - startupBufferedFrames_;
  const std::size_t startupFramesFromInput =
      std::min(inputFrames, startupFramesNeeded);
  const std::size_t processableInputFrames =
      inputFrames - startupFramesFromInput;
  RampState finalState{appliedRatio_, outputFrameRemainder_,
                       rampFramesRemaining_, lastProcessRatio_};
  const std::size_t requiredOutputFrames =
      simulateOutputFrames(processableInputFrames, finalState);
  if (requiredOutputFrames > outputCapacityFrames ||
      requiredOutputFrames > maximumOutputFrames_) {
    throw std::length_error(
        "BUFFER_TOO_SMALL: output capacity is below the required frame count");
  }

  const auto processStarted = std::chrono::steady_clock::now();
  const std::size_t channelCount = static_cast<std::size_t>(channels_);
  for (std::size_t frame = 0; frame < inputFrames; ++frame) {
    const std::size_t interleavedOffset = frame * channelCount;
    for (int channel = 0; channel < channels_; ++channel) {
      inputPlanarStorage_[static_cast<std::size_t>(channel) *
                              kMaximumInputFramesPerCall +
                          frame] =
          input[interleavedOffset + static_cast<std::size_t>(channel)];
    }
  }

  std::size_t inputOffset = 0;
  if (!startupPrimed_) {
    for (int channel = 0; channel < channels_; ++channel) {
      const std::size_t channelIndex = static_cast<std::size_t>(channel);
      const float *source =
          inputPlanarStorage_.data() +
          channelIndex * kMaximumInputFramesPerCall;
      float *destination =
          startupPlanarStorage_.data() +
          channelIndex * kMaximumInputFramesPerCall + startupBufferedFrames_;
      std::copy_n(source, startupFramesFromInput, destination);
    }
    startupBufferedFrames_ += startupFramesFromInput;
    startupMediaFrames_ += startupFramesFromInput;
    inputOffset = startupFramesFromInput;
    hasProcessedSinceReset_ = true;
    if (startupBufferedFrames_ == startupRequiredFrames_) {
      primeStartup();
    }
  }

  if (processableInputFrames == 0) {
    const auto elapsed = std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::steady_clock::now() - processStarted);
    updateProcessMetrics(static_cast<std::uint64_t>(elapsed.count()));
    return 0;
  }

  RampState processState{appliedRatio_, outputFrameRemainder_,
                         rampFramesRemaining_, lastProcessRatio_};
  std::size_t outputOffset = 0;
  std::size_t remainingInput = processableInputFrames;
  const std::size_t rampSegmentFrames = static_cast<std::size_t>(
      std::max(64, sampleRate_ / 200)); // Five milliseconds.

  while (remainingInput > 0) {
    const std::size_t segmentInputFrames =
        processState.remainingFrames > 0
            ? std::min(remainingInput, rampSegmentFrames)
            : remainingInput;
    const std::uint64_t rampAdvance =
        std::min<std::uint64_t>(segmentInputFrames,
                                processState.remainingFrames);
    double endRatio = processState.appliedRatio;
    if (processState.remainingFrames > 0) {
      const double progress =
          static_cast<double>(rampAdvance) /
          static_cast<double>(processState.remainingFrames);
      endRatio += (targetRatio_ - processState.appliedRatio) * progress;
    }
    const double processRatio =
        (processState.appliedRatio + endRatio) * 0.5;
    const double exactOutputFrames =
        static_cast<double>(segmentInputFrames) / processRatio +
        processState.outputFrameRemainder;
    const std::size_t segmentOutputFrames =
        static_cast<std::size_t>(std::floor(exactOutputFrames));

    for (int channel = 0; channel < channels_; ++channel) {
      const std::size_t channelIndex = static_cast<std::size_t>(channel);
      inputChannels_[channelIndex] =
          inputPlanarStorage_.data() +
          channelIndex * kMaximumInputFramesPerCall + inputOffset;
      outputChannels_[channelIndex] =
          outputPlanarStorage_.data() +
          channelIndex * maximumOutputFrames_ + outputOffset;
    }

#if HOMESPOTIFY_STRETCH_HAS_SIGNALSMITH
    impl_->stretcher.process(inputChannels_.data(),
                             static_cast<int>(segmentInputFrames),
                             outputChannels_.data(),
                             static_cast<int>(segmentOutputFrames));
#else
    throw std::runtime_error(
        "NATIVE_LIBRARY_UNAVAILABLE: Signalsmith vendor is not compiled");
#endif

    processState.outputFrameRemainder =
        exactOutputFrames - static_cast<double>(segmentOutputFrames);
    processState.appliedRatio = endRatio;
    processState.remainingFrames -= rampAdvance;
    if (processState.remainingFrames == 0) {
      processState.appliedRatio = targetRatio_;
    }
    processState.lastProcessRatio = processRatio;
    inputOffset += segmentInputFrames;
    outputOffset += segmentOutputFrames;
    remainingInput -= segmentInputFrames;
  }

  for (std::size_t frame = 0; frame < outputOffset; ++frame) {
    const std::size_t interleavedOffset = frame * channelCount;
    for (int channel = 0; channel < channels_; ++channel) {
      output[interleavedOffset + static_cast<std::size_t>(channel)] =
          outputPlanarStorage_[static_cast<std::size_t>(channel) *
                                   maximumOutputFrames_ +
                               frame];
    }
  }

  appliedRatio_ = processState.appliedRatio;
  outputFrameRemainder_ = processState.outputFrameRemainder;
  rampFramesRemaining_ = processState.remainingFrames;
  lastProcessRatio_ = processState.lastProcessRatio;
  hasProcessedSinceReset_ = true;
  outputFramesProduced_ += outputOffset;
  metricAppliedRatio_.store(appliedRatio_, std::memory_order_relaxed);

  const auto elapsed = std::chrono::duration_cast<std::chrono::nanoseconds>(
      std::chrono::steady_clock::now() - processStarted);
  updateProcessMetrics(static_cast<std::uint64_t>(elapsed.count()));
  return outputOffset;
}

std::size_t HomeSpotifyStretchEngine::flush(
    float *output, std::size_t outputSampleCapacity,
    std::size_t outputCapacityFrames) {
  ensureInitialized();
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
  const std::size_t requiredFrames = remainingFlushFrames();
  if (requiredFrames > outputCapacityFrames ||
      requiredFrames > maximumOutputFrames_) {
    throw std::length_error(
        "BUFFER_TOO_SMALL: flush capacity is below the DSP tail size");
  }
  if (!startupPrimed_) {
    primeStartup();
  }

  for (int channel = 0; channel < channels_; ++channel) {
    const std::size_t channelIndex = static_cast<std::size_t>(channel);
    outputChannels_[channelIndex] =
        outputPlanarStorage_.data() + channelIndex * maximumOutputFrames_;
  }
  if (requiredFrames > 0) {
    impl_->stretcher.flush(outputChannels_.data(),
                           static_cast<int>(requiredFrames),
                           lastProcessRatio_);
  }

  const std::size_t channelCount = static_cast<std::size_t>(channels_);
  for (std::size_t frame = 0; frame < requiredFrames; ++frame) {
    for (int channel = 0; channel < channels_; ++channel) {
      output[frame * channelCount + static_cast<std::size_t>(channel)] =
          outputPlanarStorage_[static_cast<std::size_t>(channel) *
                                   maximumOutputFrames_ +
                               frame];
    }
  }
  outputFramesProduced_ += requiredFrames;
  flushed_ = true;
  return requiredFrames;
#else
  throw std::runtime_error(
      "NATIVE_LIBRARY_UNAVAILABLE: Signalsmith vendor is not compiled");
#endif
}

void HomeSpotifyStretchEngine::reset() {
  ensureInitialized();
#if HOMESPOTIFY_STRETCH_HAS_SIGNALSMITH
  // A reset boundary is the only safe place to change the STFT geometry.
  // In production the effective profile never changes, so this stays a
  // plain, allocation-free stretcher reset on the audio thread.
  const StretchProfile boundaryProfile = effectiveProfile(1.0);
  if (activeProfile_ != boundaryProfile) {
    configureProfile(boundaryProfile);
    activeProfile_ = boundaryProfile;
  } else {
    impl_->stretcher.reset();
  }
#endif
  requestedProfile_ = activeProfile_;
  profileChangePending_ = false;
  targetRatio_ = 1.0;
  appliedRatio_ = 1.0;
  lastProcessRatio_ = 1.0;
  outputFrameRemainder_ = 0.0;
  rampFramesRemaining_ = 0;
  hasProcessedSinceReset_ = false;
  flushed_ = false;
  outputFramesProduced_ = 0;
  prepareStartup();

  metricActiveProfile_.store(static_cast<int>(activeProfile_),
                             std::memory_order_relaxed);
  metricRequestedProfile_.store(static_cast<int>(requestedProfile_),
                                std::memory_order_relaxed);
  metricTargetRatio_.store(1.0, std::memory_order_relaxed);
  metricAppliedRatio_.store(1.0, std::memory_order_relaxed);
  metricProfilePending_.store(false, std::memory_order_relaxed);
  clearLastError();
}

int HomeSpotifyStretchEngine::getLatencyFrames() const {
  ensureInitialized();
#if HOMESPOTIFY_STRETCH_HAS_SIGNALSMITH
  return impl_->stretcher.inputLatency() + impl_->stretcher.outputLatency();
#else
  return 0;
#endif
}

std::size_t HomeSpotifyStretchEngine::getExpectedOutputFrames(
    std::size_t inputFrames) const {
  ensureInitialized();
  if (inputFrames > kMaximumInputFramesPerCall) {
    throw std::invalid_argument(
        "INVALID_ARGUMENT: input exceeds the realtime frame limit");
  }
  if (inputFrames == 0) {
    if (!hasProcessedSinceReset_ || flushed_) {
      return 0;
    }
    return remainingFlushFrames();
  }
  const std::size_t startupFramesNeeded =
      startupPrimed_ ? 0 : startupRequiredFrames_ - startupBufferedFrames_;
  const std::size_t processableInputFrames =
      inputFrames - std::min(inputFrames, startupFramesNeeded);
  RampState state{appliedRatio_, outputFrameRemainder_,
                  rampFramesRemaining_, lastProcessRatio_};
  return simulateOutputFrames(processableInputFrames, state);
}

double HomeSpotifyStretchEngine::getAppliedTempoRatio() const noexcept {
  return metricAppliedRatio_.load(std::memory_order_relaxed);
}

StretchProfile HomeSpotifyStretchEngine::getProfile() const noexcept {
  return static_cast<StretchProfile>(
      metricActiveProfile_.load(std::memory_order_relaxed));
}

std::string HomeSpotifyStretchEngine::getMetricsJson() const {
  const std::uint64_t count =
      processCount_.load(std::memory_order_relaxed);
  const std::uint64_t total =
      totalProcessNanoseconds_.load(std::memory_order_relaxed);
  std::string lastError;
  {
    std::lock_guard<std::mutex> lock(lastErrorMutex_);
    lastError = lastError_;
  }
  const auto activeProfile = static_cast<StretchProfile>(
      metricActiveProfile_.load(std::memory_order_relaxed));
  const auto requestedProfile = static_cast<StretchProfile>(
      metricRequestedProfile_.load(std::memory_order_relaxed));

  std::ostringstream json;
  json << '{' << "\"engineName\":\"HomeSpotify Stretch Engine\","
       << "\"foundation\":\"Signalsmith Stretch\","
       << "\"foundationVersion\":\"1.3.2\","
       << "\"engineVersion\":\"production-0.1.0\","
       << "\"available\":" << (isAvailable() ? "true" : "false") << ','
       << "\"initialized\":"
       << (metricInitialized_.load(std::memory_order_acquire) ? "true"
                                                             : "false")
       << ',' << "\"sampleRate\":"
       << metricSampleRate_.load(std::memory_order_relaxed) << ','
       << "\"channels\":"
       << metricChannels_.load(std::memory_order_relaxed) << ','
       << "\"pitchRatio\":1.0," << "\"targetRatio\":"
       << metricTargetRatio_.load(std::memory_order_relaxed) << ','
       << "\"appliedRatio\":"
       << metricAppliedRatio_.load(std::memory_order_relaxed) << ','
       << "\"activeProfile\":\"" << profileName(activeProfile) << "\","
       << "\"requestedProfile\":\"" << profileName(requestedProfile)
       << "\"," << "\"profileOverride\":" << profileOverride_ << ','
       << "\"profileChangePending\":"
       << (metricProfilePending_.load(std::memory_order_relaxed) ? "true"
                                                                : "false")
       << ',' << "\"latencyFrames\":"
       << metricLatencyFrames_.load(std::memory_order_relaxed) << ','
       << "\"processCount\":" << count << ','
       << "\"averageProcessMicros\":"
       << (count == 0 ? 0.0
                      : static_cast<double>(total) /
                            static_cast<double>(count) / 1000.0)
       << ',' << "\"maximumProcessMicros\":"
       << static_cast<double>(maximumProcessNanoseconds_.load(
              std::memory_order_relaxed)) /
              1000.0
       << ',' << "\"lastProcessMicros\":"
       << static_cast<double>(
              lastProcessNanoseconds_.load(std::memory_order_relaxed)) /
              1000.0
       << ',' << "\"lastError\":\"" << escapeJson(lastError) << "\"" << '}';
  return json.str();
}

void HomeSpotifyStretchEngine::recordLastError(
    const std::string &message) noexcept {
  try {
    std::lock_guard<std::mutex> lock(lastErrorMutex_);
    lastError_ = message.substr(0, 512);
  } catch (...) {
    return;
  }
}

void HomeSpotifyStretchEngine::dispose() noexcept {
  if (disposed_) {
    return;
  }
  metricInitialized_.store(false, std::memory_order_release);
  initialized_ = false;
  disposed_ = true;
  impl_.reset();
  inputPlanarStorage_.clear();
  outputPlanarStorage_.clear();
  startupPlanarStorage_.clear();
  maximumOutputFrames_ = 0;
  startupRequiredFrames_ = 0;
  startupBufferedFrames_ = 0;
  startupMediaFrames_ = 0;
  outputFramesProduced_ = 0;
  startupPrimed_ = false;
  sampleRate_ = 0;
  channels_ = 0;
  metricSampleRate_.store(0, std::memory_order_relaxed);
  metricChannels_.store(0, std::memory_order_relaxed);
  metricLatencyFrames_.store(0, std::memory_order_relaxed);
}

bool HomeSpotifyStretchEngine::isAvailable() const noexcept {
#if HOMESPOTIFY_STRETCH_HAS_SIGNALSMITH
  return true;
#else
  return false;
#endif
}

bool HomeSpotifyStretchEngine::isInitialized() const noexcept {
  return metricInitialized_.load(std::memory_order_acquire);
}

int HomeSpotifyStretchEngine::channels() const noexcept {
  return metricChannels_.load(std::memory_order_relaxed);
}

int HomeSpotifyStretchEngine::sampleRate() const noexcept {
  return metricSampleRate_.load(std::memory_order_relaxed);
}

StretchProfile HomeSpotifyStretchEngine::selectProfile(double ratio) {
  if (!std::isfinite(ratio) || ratio < kMinimumTempoRatio - kRatioTolerance ||
      ratio > kMaximumTempoRatio + kRatioTolerance) {
    throw std::invalid_argument(
        "INVALID_ARGUMENT: tempo ratio must be between 0.70 and 1.30");
  }
  // Production intentionally maps every active ratio to one calibrated
  // configuration. Ratio-driven switching cannot be applied mid-stream
  // (Signalsmith reconfiguration resets the STFT), so range-based profiles
  // silently latched the profile of the first non-unit ratio — measured as
  // presetCheaper serving 1.30x after a live slider move, which is the
  // metallic vocal colouration this engine must not have. At 1.00x the
  // processor is bypassed entirely, so no low-cost profile is needed.
  return StretchProfile::musical;
}

StretchProfile HomeSpotifyStretchEngine::effectiveProfile(double ratio) const {
  const StretchProfile production = selectProfile(ratio);
  if (profileOverride_ >= 0 && profileOverride_ <= 2) {
    return static_cast<StretchProfile>(profileOverride_);
  }
  return production;
}

void HomeSpotifyStretchEngine::setProfileOverride(int profileOrdinal) {
  if (profileOrdinal < -1 || profileOrdinal > 2) {
    throw std::invalid_argument(
        "INVALID_ARGUMENT: profile override must be -1 (auto) or 0..2");
  }
  profileOverride_ = profileOrdinal;
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

void HomeSpotifyStretchEngine::ensureAvailable() const {
  if (!isAvailable()) {
    throw std::runtime_error(
        "NATIVE_LIBRARY_UNAVAILABLE: Signalsmith vendor is not compiled");
  }
}

void HomeSpotifyStretchEngine::ensureInitialized() const {
  ensureAvailable();
  if (disposed_) {
    throw std::runtime_error("DISPOSED: native stretch engine was disposed");
  }
  if (!initialized_ || !impl_) {
    throw std::runtime_error(
        "NOT_INITIALIZED: initialize must be called before processing");
  }
}

void HomeSpotifyStretchEngine::configureProfile(StretchProfile profile) {
#if HOMESPOTIFY_STRETCH_HAS_SIGNALSMITH
  ensureAvailable();
  switch (profile) {
  case StretchProfile::transparent:
    impl_->stretcher.presetCheaper(channels_, sampleRate_, true);
    break;
  case StretchProfile::musical:
    impl_->stretcher.presetDefault(channels_, sampleRate_, true);
    break;
  case StretchProfile::extremeHq:
    // 120 ms block / 20 ms interval: same block as presetDefault (transient
    // behaviour preserved) with 6x overlap for denser phase tracking. The
    // previous 160 ms block bought slightly steadier bass at the cost of
    // 180 ms latency and more transient smearing on voices.
    impl_->stretcher.configure(
        channels_, static_cast<int>(std::lround(sampleRate_ * 0.120)),
        static_cast<int>(std::lround(sampleRate_ * 0.020)), true);
    break;
  }
  impl_->stretcher.setTransposeFactor(1.0f);
  metricLatencyFrames_.store(
      impl_->stretcher.inputLatency() + impl_->stretcher.outputLatency(),
      std::memory_order_relaxed);
#else
  (void)profile;
#endif
}

void HomeSpotifyStretchEngine::allocateRealtimeBuffers() {
  const std::size_t processOutputFrames = static_cast<std::size_t>(
      std::ceil(static_cast<double>(kMaximumInputFramesPerCall) /
                kMinimumTempoRatio)) +
                                          4;
  const std::size_t latencyReserveFrames = static_cast<std::size_t>(
      std::ceil(static_cast<double>(sampleRate_) * 0.75));
  maximumOutputFrames_ =
      std::max(processOutputFrames, latencyReserveFrames);
  const std::size_t channelCount = static_cast<std::size_t>(channels_);
  inputPlanarStorage_.assign(kMaximumInputFramesPerCall * channelCount, 0.0f);
  startupPlanarStorage_.assign(kMaximumInputFramesPerCall * channelCount,
                               0.0f);
  outputPlanarStorage_.assign(maximumOutputFrames_ * channelCount, 0.0f);
}

void HomeSpotifyStretchEngine::prepareStartup() {
#if HOMESPOTIFY_STRETCH_HAS_SIGNALSMITH
  startupRatio_ = std::clamp(appliedRatio_, kMinimumTempoRatio,
                             kMaximumTempoRatio);
  const int required = impl_->stretcher.outputSeekLength(startupRatio_);
  if (required <= 0 ||
      static_cast<std::size_t>(required) > kMaximumInputFramesPerCall) {
    throw std::runtime_error(
        "UNSUPPORTED_FORMAT: Signalsmith startup latency exceeds the realtime buffer");
  }
  startupRequiredFrames_ = static_cast<std::size_t>(required);
  startupBufferedFrames_ = 0;
  startupMediaFrames_ = 0;
  startupPrimed_ = false;
#else
  throw std::runtime_error(
      "NATIVE_LIBRARY_UNAVAILABLE: Signalsmith vendor is not compiled");
#endif
}

void HomeSpotifyStretchEngine::primeStartup() {
  if (startupPrimed_) {
    return;
  }
  if (startupBufferedFrames_ > startupRequiredFrames_) {
    throw std::runtime_error(
        "INVALID_STATE: startup buffer exceeds the Signalsmith pre-roll");
  }
  for (int channel = 0; channel < channels_; ++channel) {
    const std::size_t channelIndex = static_cast<std::size_t>(channel);
    float *channelStart =
        startupPlanarStorage_.data() +
        channelIndex * kMaximumInputFramesPerCall;
    std::fill(channelStart + startupBufferedFrames_,
              channelStart + startupRequiredFrames_, 0.0f);
    startupChannels_[channelIndex] = channelStart;
  }
#if HOMESPOTIFY_STRETCH_HAS_SIGNALSMITH
  impl_->stretcher.outputSeek(startupChannels_.data(),
                              static_cast<int>(startupRequiredFrames_));
  startupPrimed_ = true;
#else
  throw std::runtime_error(
      "NATIVE_LIBRARY_UNAVAILABLE: Signalsmith vendor is not compiled");
#endif
}

std::size_t HomeSpotifyStretchEngine::remainingFlushFrames() const {
  const double deferredStartupFrames =
      static_cast<double>(startupMediaFrames_) / startupRatio_;
  const double exactTotalFrames =
      static_cast<double>(outputFramesProduced_) + outputFrameRemainder_ +
      deferredStartupFrames;
  const std::uint64_t desiredTotalFrames = static_cast<std::uint64_t>(
      std::max(0.0, std::floor(exactTotalFrames + 0.5)));
  if (desiredTotalFrames <= outputFramesProduced_) {
    return 0;
  }
  const std::uint64_t remaining =
      desiredTotalFrames - outputFramesProduced_;
  if (remaining > std::numeric_limits<std::size_t>::max()) {
    throw std::overflow_error(
        "NATIVE_PROCESSING_FAILED: flush frame count overflow");
  }
  return static_cast<std::size_t>(remaining);
}

std::size_t HomeSpotifyStretchEngine::simulateOutputFrames(
    std::size_t inputFrames, RampState &state) const {
  std::size_t outputFrames = 0;
  std::size_t remainingInput = inputFrames;
  const std::size_t rampSegmentFrames = static_cast<std::size_t>(
      std::max(64, sampleRate_ / 200));
  while (remainingInput > 0) {
    const std::size_t segmentInputFrames =
        state.remainingFrames > 0
            ? std::min(remainingInput, rampSegmentFrames)
            : remainingInput;
    const std::uint64_t rampAdvance =
        std::min<std::uint64_t>(segmentInputFrames, state.remainingFrames);
    double endRatio = state.appliedRatio;
    if (state.remainingFrames > 0) {
      const double progress =
          static_cast<double>(rampAdvance) /
          static_cast<double>(state.remainingFrames);
      endRatio += (targetRatio_ - state.appliedRatio) * progress;
    }
    const double processRatio = (state.appliedRatio + endRatio) * 0.5;
    const double exactOutputFrames =
        static_cast<double>(segmentInputFrames) / processRatio +
        state.outputFrameRemainder;
    const std::size_t segmentOutputFrames =
        static_cast<std::size_t>(std::floor(exactOutputFrames));
    outputFrames += segmentOutputFrames;
    state.outputFrameRemainder =
        exactOutputFrames - static_cast<double>(segmentOutputFrames);
    state.appliedRatio = endRatio;
    state.remainingFrames -= rampAdvance;
    if (state.remainingFrames == 0) {
      state.appliedRatio = targetRatio_;
    }
    state.lastProcessRatio = processRatio;
    remainingInput -= segmentInputFrames;
  }
  return outputFrames;
}

void HomeSpotifyStretchEngine::updateProcessMetrics(
    std::uint64_t elapsedNanoseconds) noexcept {
  processCount_.fetch_add(1, std::memory_order_relaxed);
  totalProcessNanoseconds_.fetch_add(elapsedNanoseconds,
                                    std::memory_order_relaxed);
  lastProcessNanoseconds_.store(elapsedNanoseconds,
                                std::memory_order_relaxed);
  std::uint64_t previousMaximum =
      maximumProcessNanoseconds_.load(std::memory_order_relaxed);
  while (previousMaximum < elapsedNanoseconds &&
         !maximumProcessNanoseconds_.compare_exchange_weak(
             previousMaximum, elapsedNanoseconds, std::memory_order_relaxed,
             std::memory_order_relaxed)) {
  }
}

void HomeSpotifyStretchEngine::clearLastError() noexcept {
  try {
    std::lock_guard<std::mutex> lock(lastErrorMutex_);
    lastError_.clear();
  } catch (...) {
    return;
  }
}

} // namespace homespotify::stretch
