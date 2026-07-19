#include "HomeSpotifyStretchEngine.h"

#include <jni.h>

#include <cstdint>
#include <exception>
#include <limits>
#include <new>
#include <stdexcept>
#include <string>

namespace {

using homespotify::stretch::HomeSpotifyStretchEngine;

void throwJava(JNIEnv *env, const char *className, const std::string &message) {
  const jclass exceptionClass = env->FindClass(className);
  if (exceptionClass != nullptr) {
    env->ThrowNew(exceptionClass, message.c_str());
  }
}

HomeSpotifyStretchEngine *engineFromHandle(jlong handle) {
  if (handle == 0) {
    throw std::invalid_argument("INVALID_ARGUMENT: native handle is null");
  }
  return reinterpret_cast<HomeSpotifyStretchEngine *>(
      static_cast<std::intptr_t>(handle));
}

void translateException(JNIEnv *env,
                        HomeSpotifyStretchEngine *engine = nullptr) {
  try {
    throw;
  } catch (const std::invalid_argument &error) {
    if (engine != nullptr) {
      engine->recordLastError(error.what());
    }
    throwJava(env, "java/lang/IllegalArgumentException", error.what());
  } catch (const std::length_error &error) {
    if (engine != nullptr) {
      engine->recordLastError(error.what());
    }
    throwJava(env, "java/lang/IndexOutOfBoundsException", error.what());
  } catch (const std::bad_alloc &error) {
    if (engine != nullptr) {
      engine->recordLastError(error.what());
    }
    throwJava(env, "java/lang/OutOfMemoryError", error.what());
  } catch (const std::exception &error) {
    if (engine != nullptr) {
      engine->recordLastError(error.what());
    }
    throwJava(env, "java/lang/IllegalStateException", error.what());
  } catch (...) {
    constexpr const char *message =
        "NATIVE_PROCESSING_FAILED: unknown native exception";
    if (engine != nullptr) {
      engine->recordLastError(message);
    }
    throwJava(env, "java/lang/RuntimeException", message);
  }
}

std::size_t checkedSize(jint value, const char *field) {
  if (value < 0) {
    throw std::invalid_argument(std::string("INVALID_ARGUMENT: ") + field +
                                " cannot be negative");
  }
  return static_cast<std::size_t>(value);
}

std::size_t checkedSampleCount(std::size_t frames, int channels) {
  if (channels <= 0 || frames > std::numeric_limits<std::size_t>::max() /
                                    static_cast<std::size_t>(channels)) {
    throw std::invalid_argument("INVALID_ARGUMENT: PCM buffer size overflow");
  }
  return frames * static_cast<std::size_t>(channels);
}

float *directFloatBuffer(JNIEnv *env, jobject buffer,
                         std::size_t requiredSamples, const char *field) {
  if (buffer == nullptr) {
    throw std::invalid_argument(std::string("INVALID_ARGUMENT: ") + field +
                                " is null");
  }
  void *address = env->GetDirectBufferAddress(buffer);
  const jlong capacityBytes = env->GetDirectBufferCapacity(buffer);
  if (address == nullptr || capacityBytes < 0) {
    throw std::invalid_argument(std::string("INVALID_ARGUMENT: ") + field +
                                " must be a direct ByteBuffer");
  }
  if (requiredSamples >
      std::numeric_limits<std::size_t>::max() / sizeof(float)) {
    throw std::invalid_argument("INVALID_ARGUMENT: PCM byte size overflow");
  }
  const std::size_t requiredBytes = requiredSamples * sizeof(float);
  if (static_cast<std::uint64_t>(capacityBytes) < requiredBytes) {
    throw std::length_error(std::string("BUFFER_TOO_SMALL: ") + field +
                            " capacity is below the requested frame count");
  }
  if (reinterpret_cast<std::uintptr_t>(address) % alignof(float) != 0) {
    throw std::invalid_argument(std::string("INVALID_ARGUMENT: ") + field +
                                " is not float-aligned");
  }
  return static_cast<float *>(address);
}

jint checkedJint(std::size_t value, const char *field) {
  if (value > static_cast<std::size_t>(std::numeric_limits<jint>::max())) {
    throw std::overflow_error(std::string("NATIVE_PROCESSING_FAILED: ") +
                              field + " exceeds the JNI integer limit");
  }
  return static_cast<jint>(value);
}

} // namespace

extern "C" JNIEXPORT jlong JNICALL
Java_com_homespotify_audio_stretch_NativeStretchBridge_create(
    JNIEnv *env, jclass /* type */) {
  try {
    auto *engine = new HomeSpotifyStretchEngine();
    return static_cast<jlong>(reinterpret_cast<std::intptr_t>(engine));
  } catch (...) {
    translateException(env);
    return 0;
  }
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_homespotify_audio_stretch_NativeStretchBridge_isAvailable(
    JNIEnv * /* env */, jclass /* type */) {
#if HOMESPOTIFY_STRETCH_HAS_SIGNALSMITH
  return JNI_TRUE;
#else
  return JNI_FALSE;
#endif
}

extern "C" JNIEXPORT void JNICALL
Java_com_homespotify_audio_stretch_NativeStretchBridge_initialize(
    JNIEnv *env, jclass /* type */, jlong handle, jint sampleRate,
    jint channels) {
  HomeSpotifyStretchEngine *engine = nullptr;
  try {
    engine = engineFromHandle(handle);
    engine->initialize(sampleRate, channels);
  } catch (...) {
    translateException(env, engine);
  }
}

extern "C" JNIEXPORT void JNICALL
Java_com_homespotify_audio_stretch_NativeStretchBridge_setRatio(
    JNIEnv *env, jclass /* type */, jlong handle, jdouble ratio,
    jint transitionFrames) {
  HomeSpotifyStretchEngine *engine = nullptr;
  try {
    engine = engineFromHandle(handle);
    engine->setTempoRatio(
        ratio, static_cast<std::uint32_t>(
                   checkedSize(transitionFrames, "transitionFrames")));
  } catch (...) {
    translateException(env, engine);
  }
}

extern "C" JNIEXPORT jint JNICALL
Java_com_homespotify_audio_stretch_NativeStretchBridge_processDirect(
    JNIEnv *env, jclass /* type */, jlong handle, jobject inputBuffer,
    jint inputFrames, jobject outputBuffer, jint outputCapacityFrames) {
  HomeSpotifyStretchEngine *engine = nullptr;
  try {
    engine = engineFromHandle(handle);
    const std::size_t frameCount = checkedSize(inputFrames, "inputFrames");
    const std::size_t capacityFrames =
        checkedSize(outputCapacityFrames, "outputCapacityFrames");
    const std::size_t inputSamples =
        checkedSampleCount(frameCount, engine->channels());
    const std::size_t outputSamples =
        checkedSampleCount(capacityFrames, engine->channels());
    const float *input =
        directFloatBuffer(env, inputBuffer, inputSamples, "inputBuffer");
    float *output =
        directFloatBuffer(env, outputBuffer, outputSamples, "outputBuffer");

    const std::uintptr_t inputStart =
        reinterpret_cast<std::uintptr_t>(input);
    const std::uintptr_t inputEnd = inputStart + inputSamples * sizeof(float);
    const std::uintptr_t outputStart =
        reinterpret_cast<std::uintptr_t>(output);
    const std::uintptr_t outputEnd =
        outputStart + outputSamples * sizeof(float);
    if (inputStart < outputEnd && outputStart < inputEnd) {
      throw std::invalid_argument(
          "INVALID_ARGUMENT: input and output buffers must not overlap");
    }

    return checkedJint(engine->process(
                           input, inputSamples, frameCount, output,
                           outputSamples, capacityFrames),
                       "output frame count");
  } catch (...) {
    translateException(env, engine);
    return 0;
  }
}

extern "C" JNIEXPORT jint JNICALL
Java_com_homespotify_audio_stretch_NativeStretchBridge_flushDirect(
    JNIEnv *env, jclass /* type */, jlong handle, jobject outputBuffer,
    jint outputCapacityFrames) {
  HomeSpotifyStretchEngine *engine = nullptr;
  try {
    engine = engineFromHandle(handle);
    const std::size_t capacityFrames =
        checkedSize(outputCapacityFrames, "outputCapacityFrames");
    const std::size_t outputSamples =
        checkedSampleCount(capacityFrames, engine->channels());
    float *output =
        directFloatBuffer(env, outputBuffer, outputSamples, "outputBuffer");
    return checkedJint(engine->flush(output, outputSamples, capacityFrames),
                       "flush frame count");
  } catch (...) {
    translateException(env, engine);
    return 0;
  }
}

extern "C" JNIEXPORT void JNICALL
Java_com_homespotify_audio_stretch_NativeStretchBridge_setProfileOverride(
    JNIEnv *env, jclass /* type */, jlong handle, jint profileOrdinal) {
  HomeSpotifyStretchEngine *engine = nullptr;
  try {
    engine = engineFromHandle(handle);
    engine->setProfileOverride(profileOrdinal);
  } catch (...) {
    translateException(env, engine);
  }
}

extern "C" JNIEXPORT void JNICALL
Java_com_homespotify_audio_stretch_NativeStretchBridge_reset(
    JNIEnv *env, jclass /* type */, jlong handle) {
  HomeSpotifyStretchEngine *engine = nullptr;
  try {
    engine = engineFromHandle(handle);
    engine->reset();
  } catch (...) {
    translateException(env, engine);
  }
}

extern "C" JNIEXPORT jint JNICALL
Java_com_homespotify_audio_stretch_NativeStretchBridge_getLatency(
    JNIEnv *env, jclass /* type */, jlong handle) {
  HomeSpotifyStretchEngine *engine = nullptr;
  try {
    engine = engineFromHandle(handle);
    return engine->getLatencyFrames();
  } catch (...) {
    translateException(env, engine);
    return 0;
  }
}

extern "C" JNIEXPORT jdouble JNICALL
Java_com_homespotify_audio_stretch_NativeStretchBridge_getApplied(
    JNIEnv *env, jclass /* type */, jlong handle) {
  HomeSpotifyStretchEngine *engine = nullptr;
  try {
    engine = engineFromHandle(handle);
    return engine->getAppliedTempoRatio();
  } catch (...) {
    translateException(env, engine);
    return 1.0;
  }
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_homespotify_audio_stretch_NativeStretchBridge_getMetrics(
    JNIEnv *env, jclass /* type */, jlong handle) {
  HomeSpotifyStretchEngine *engine = nullptr;
  try {
    engine = engineFromHandle(handle);
    const std::string metrics = engine->getMetricsJson();
    return env->NewStringUTF(metrics.c_str());
  } catch (...) {
    translateException(env, engine);
    return nullptr;
  }
}

extern "C" JNIEXPORT void JNICALL
Java_com_homespotify_audio_stretch_NativeStretchBridge_dispose(
    JNIEnv * /* env */, jclass /* type */, jlong handle) {
  if (handle == 0) {
    return;
  }
  auto *engine = reinterpret_cast<HomeSpotifyStretchEngine *>(
      static_cast<std::intptr_t>(handle));
  engine->dispose();
  delete engine;
}
