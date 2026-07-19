#ifndef HOMESPOTIFY_STRETCH_ENGINE_H
#define HOMESPOTIFY_STRETCH_ENGINE_H

#include <cstddef>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>

namespace homespotify::stretch {

enum class StretchProfile {
  transparent,
  musical,
  extremeHq,
};

class HomeSpotifyStretchEngine final {
public:
  static constexpr double kMinimumTempoRatio = 0.70;
  static constexpr double kMaximumTempoRatio = 1.30;
  static constexpr double kFixedPitchRatio = 1.00;

  HomeSpotifyStretchEngine();
  ~HomeSpotifyStretchEngine();

  HomeSpotifyStretchEngine(const HomeSpotifyStretchEngine &) = delete;
  HomeSpotifyStretchEngine &
  operator=(const HomeSpotifyStretchEngine &) = delete;

  void initialize(int sampleRate, int channels);
  void setTempoRatio(double ratio);

  std::size_t process(const float *input, std::size_t inputSampleCount,
                      std::size_t inputFrames, float *output,
                      std::size_t outputSampleCapacity,
                      std::size_t outputCapacityFrames);

  std::size_t flush(float *output, std::size_t outputSampleCapacity,
                    std::size_t outputCapacityFrames);

  void reset();
  int getLatencyFrames() const;
  std::size_t getRequiredOutputFrames(std::size_t inputFrames) const;
  double getAppliedRatio() const;
  std::string getEngineInfo() const;
  void recordLastError(std::string message) noexcept;
  void dispose() noexcept;

  bool isAvailable() const noexcept;
  bool isInitialized() const noexcept;
  int channels() const noexcept;
  int sampleRate() const noexcept;

  static StretchProfile selectProfile(double ratio);
  static const char *profileName(StretchProfile profile) noexcept;

private:
  class Impl;

  void ensureAvailableLocked() const;
  void ensureInitializedLocked() const;
  void configureProfileLocked(StretchProfile profile);
  void applyPendingProfileLocked();

  mutable std::mutex mutex_;
  std::unique_ptr<Impl> impl_;
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
  std::int64_t rampFramesRemaining_ = 0;
  StretchProfile activeProfile_ = StretchProfile::transparent;
  StretchProfile requestedProfile_ = StretchProfile::transparent;
  bool profileChangePending_ = false;
  std::string lastError_;
};

} // namespace homespotify::stretch

#endif // HOMESPOTIFY_STRETCH_ENGINE_H
