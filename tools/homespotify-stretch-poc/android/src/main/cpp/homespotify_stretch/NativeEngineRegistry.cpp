#include "NativeEngineRegistry.h"

#include <stdexcept>

namespace homespotify::stretch {

NativeEngineRegistry &NativeEngineRegistry::instance() {
  static NativeEngineRegistry registry;
  return registry;
}

std::int64_t NativeEngineRegistry::create() {
  const std::int64_t handle = nextHandle_.fetch_add(1);
  if (handle <= 0) {
    throw std::overflow_error(
        "NATIVE_PROCESSING_FAILED: native handle overflow");
  }
  auto engine = std::make_shared<HomeSpotifyStretchEngine>();
  std::lock_guard<std::mutex> lock(mutex_);
  engines_.emplace(handle, std::move(engine));
  return handle;
}

std::shared_ptr<HomeSpotifyStretchEngine>
NativeEngineRegistry::get(std::int64_t handle) const {
  if (handle <= 0) {
    throw std::invalid_argument("INVALID_ARGUMENT: native handle is invalid");
  }
  std::lock_guard<std::mutex> lock(mutex_);
  const auto found = engines_.find(handle);
  if (found == engines_.end()) {
    throw std::runtime_error("DISPOSED: native engine handle is not active");
  }
  return found->second;
}

void NativeEngineRegistry::recordLastError(
    std::int64_t handle, const std::string &message) noexcept {
  try {
    std::shared_ptr<HomeSpotifyStretchEngine> engine;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      const auto found = engines_.find(handle);
      if (found == engines_.end()) {
        return;
      }
      engine = found->second;
    }
    engine->recordLastError(message);
  } catch (...) {
    return;
  }
}

void NativeEngineRegistry::dispose(std::int64_t handle) noexcept {
  std::shared_ptr<HomeSpotifyStretchEngine> engine;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    const auto found = engines_.find(handle);
    if (found == engines_.end()) {
      return;
    }
    engine = std::move(found->second);
    engines_.erase(found);
  }
  engine->dispose();
}

} // namespace homespotify::stretch
