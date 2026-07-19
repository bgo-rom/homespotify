#ifndef HOMESPOTIFY_STRETCH_ENGINE_H
#define HOMESPOTIFY_STRETCH_ENGINE_H

#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace homespotify::stretch {

enum class StretchProfile : int {
  transparent = 0,
  musical = 1,
  extremeHq = 2,
};

// Owned and called serially by Media3's audio thread. Metrics are atomic so a
// diagnostic thread can read them without taking a lock in the PCM path.
class HomeSpotifyStretchEngine final {
public:
  static constexpr double kMinimumTempoRatio = 0.70;
  static constexpr double kMaximumTempoRatio = 1.30;
  static constexpr double kFixedPitchRatio = 1.00;
  static constexpr std::size_t kMaximumInputFramesPerCall = 65536;

  HomeSpotifyStretchEngine();
  ~HomeSpotifyStretchEngine();

  HomeSpotifyStretchEngine(const HomeSpotifyStretchEngine &) = delete;
  HomeSpotifyStretchEngine &
  operator=(const HomeSpotifyStretchEngine &) = delete;

  void initialize(int sampleRate, int channels);
  void configure(StretchProfile profile, double tempoRatio);
  // Calibration/dev only: explicit Signalsmith block geometry, same reset
  // boundary contract as configure(). Production always goes through profiles.
  void configureCustom(int blockSamples, int intervalSamples,
                       bool splitComputation, double tempoRatio);
  // Dev/A-B only. ordinal in [0, 2] pins a profile, -1 restores production
  // behaviour. Applied at the next reset boundary, never mid-stream.
  void setProfileOverride(int profileOrdinal);
  void setTempoRatio(double ratio, std::uint32_t transitionFrames);

  std::size_t process(const float *input, std::size_t inputSampleCount,
                      std::size_t inputFrames, float *output,
                      std::size_t outputSampleCapacity,
                      std::size_t outputCapacityFrames);
  std::size_t flush(float *output, std::size_t outputSampleCapacity,
                    std::size_t outputCapacityFrames);

  void reset();
  int getLatencyFrames() const;
  std::size_t getExpectedOutputFrames(std::size_t inputFrames) const;
  double getAppliedTempoRatio() const noexcept;
  StretchProfile getProfile() const noexcept;
  std::string getMetricsJson() const;
  void recordLastError(const std::string &message) noexcept;
  void dispose() noexcept;

  bool isAvailable() const noexcept;
  bool isInitialized() const noexcept;
  int channels() const noexcept;
  int sampleRate() const noexcept;

  static StretchProfile selectProfile(double ratio);
  static const char *profileName(StretchProfile profile) noexcept;

private:
  class Impl;

  struct RampState {
    double appliedRatio;
    double outputFrameRemainder;
    std::uint64_t remainingFrames;
    double lastProcessRatio;
  };

  void ensureAvailable() const;
  void ensureInitialized() const;
  StretchProfile effectiveProfile(double ratio) const;
  void configureProfile(StretchProfile profile);
  void allocateRealtimeBuffers();
  void prepareStartup();
  void primeStartup();
  std::size_t remainingFlushFrames() const;
  std::size_t simulateOutputFrames(std::size_t inputFrames,
                                   RampState &state) const;
  void updateProcessMetrics(std::uint64_t elapsedNanoseconds) noexcept;
  void clearLastError() noexcept;

  std::unique_ptr<Impl> impl_;
  std::vector<float> inputPlanarStorage_;
  std::vector<float> outputPlanarStorage_;
  std::vector<float> startupPlanarStorage_;
  std::array<float *, 2> inputChannels_{};
  std::array<float *, 2> outputChannels_{};
  std::array<float *, 2> startupChannels_{};

  std::size_t maximumOutputFrames_ = 0;
  int sampleRate_ = 0;
  int channels_ = 0;
  bool initialized_ = false;
  bool disposed_ = false;
  bool hasProcessedSinceReset_ = false;
  bool flushed_ = false;
  double targetRatio_ = 1.0;
  double appliedRatio_ = 1.0;
  double lastProcessRatio_ = 1.0;
  double outputFrameRemainder_ = 0.0;
  std::uint64_t rampFramesRemaining_ = 0;
  std::size_t startupRequiredFrames_ = 0;
  std::size_t startupBufferedFrames_ = 0;
  std::size_t startupMediaFrames_ = 0;
  std::uint64_t outputFramesProduced_ = 0;
  double startupRatio_ = 1.0;
  bool startupPrimed_ = false;
  StretchProfile activeProfile_ = StretchProfile::musical;
  StretchProfile requestedProfile_ = StretchProfile::musical;
  int profileOverride_ = -1;
  bool profileChangePending_ = false;

  std::atomic<std::uint64_t> processCount_{0};
  std::atomic<std::uint64_t> totalProcessNanoseconds_{0};
  std::atomic<std::uint64_t> maximumProcessNanoseconds_{0};
  std::atomic<std::uint64_t> lastProcessNanoseconds_{0};
  std::atomic<int> metricSampleRate_{0};
  std::atomic<int> metricChannels_{0};
  std::atomic<int> metricLatencyFrames_{0};
  std::atomic<int> metricActiveProfile_{0};
  std::atomic<int> metricRequestedProfile_{0};
  std::atomic<double> metricTargetRatio_{1.0};
  std::atomic<double> metricAppliedRatio_{1.0};
  std::atomic<bool> metricInitialized_{false};
  std::atomic<bool> metricProfilePending_{false};

  mutable std::mutex lastErrorMutex_;
  std::string lastError_;
};

} // namespace homespotify::stretch

#endif // HOMESPOTIFY_STRETCH_ENGINE_H
