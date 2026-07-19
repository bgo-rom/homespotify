#ifndef HOMESPOTIFY_STRETCH_NATIVE_ENGINE_REGISTRY_H
#define HOMESPOTIFY_STRETCH_NATIVE_ENGINE_REGISTRY_H

#include "HomeSpotifyStretchEngine.h"

#include <atomic>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>

namespace homespotify::stretch {

class NativeEngineRegistry final {
public:
  static NativeEngineRegistry &instance();

  std::int64_t create();
  std::shared_ptr<HomeSpotifyStretchEngine> get(std::int64_t handle) const;
  void recordLastError(std::int64_t handle,
                       const std::string &message) noexcept;
  void dispose(std::int64_t handle) noexcept;

private:
  NativeEngineRegistry() = default;

  mutable std::mutex mutex_;
  std::atomic<std::int64_t> nextHandle_{1};
  std::unordered_map<std::int64_t, std::shared_ptr<HomeSpotifyStretchEngine>>
      engines_;
};

} // namespace homespotify::stretch

#endif // HOMESPOTIFY_STRETCH_NATIVE_ENGINE_REGISTRY_H
