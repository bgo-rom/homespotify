#include "NativeEngineRegistry.h"

#include <jni.h>

#include <exception>
#include <limits>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

using homespotify::stretch::NativeEngineRegistry;

void throwJava(JNIEnv *env, const char *className, const std::string &message) {
  const jclass exceptionClass = env->FindClass(className);
  if (exceptionClass != nullptr) {
    env->ThrowNew(exceptionClass, message.c_str());
  }
}

void translateException(JNIEnv *env, jlong handle = 0) {
  try {
    throw;
  } catch (const std::invalid_argument &error) {
    NativeEngineRegistry::instance().recordLastError(
        static_cast<std::int64_t>(handle), error.what());
    throwJava(env, "java/lang/IllegalArgumentException", error.what());
  } catch (const std::length_error &error) {
    NativeEngineRegistry::instance().recordLastError(
        static_cast<std::int64_t>(handle), error.what());
    throwJava(env, "java/lang/IndexOutOfBoundsException", error.what());
  } catch (const std::bad_alloc &error) {
    NativeEngineRegistry::instance().recordLastError(
        static_cast<std::int64_t>(handle), error.what());
    throwJava(env, "java/lang/OutOfMemoryError", error.what());
  } catch (const std::exception &error) {
    NativeEngineRegistry::instance().recordLastError(
        static_cast<std::int64_t>(handle), error.what());
    throwJava(env, "java/lang/IllegalStateException", error.what());
  } catch (...) {
    NativeEngineRegistry::instance().recordLastError(
        static_cast<std::int64_t>(handle),
        "NATIVE_PROCESSING_FAILED: unknown native exception");
    throwJava(env, "java/lang/RuntimeException",
              "NATIVE_PROCESSING_FAILED: unknown native exception");
  }
}

std::size_t checkedSize(jint value, const char *field) {
  if (value < 0) {
    throw std::invalid_argument(std::string("INVALID_ARGUMENT: ") + field +
                                " cannot be negative");
  }
  return static_cast<std::size_t>(value);
}

} // namespace

extern "C" JNIEXPORT jlong JNICALL
Java_com_homespotify_stretchpoc_HomeSpotifyStretchPocPlugin_00024NativeBindings_nativeCreate(
    JNIEnv *env, jobject /* receiver */) {
  try {
    return static_cast<jlong>(NativeEngineRegistry::instance().create());
  } catch (...) {
    translateException(env);
    return 0;
  }
}

extern "C" JNIEXPORT void JNICALL
Java_com_homespotify_stretchpoc_HomeSpotifyStretchPocPlugin_00024NativeBindings_nativeInitialize(
    JNIEnv *env, jobject /* receiver */, jlong handle, jint sampleRate,
    jint channels) {
  try {
    NativeEngineRegistry::instance()
        .get(static_cast<std::int64_t>(handle))
        ->initialize(sampleRate, channels);
  } catch (...) {
    translateException(env, handle);
  }
}

extern "C" JNIEXPORT void JNICALL
Java_com_homespotify_stretchpoc_HomeSpotifyStretchPocPlugin_00024NativeBindings_nativeSetTempoRatio(
    JNIEnv *env, jobject /* receiver */, jlong handle, jdouble ratio) {
  try {
    NativeEngineRegistry::instance()
        .get(static_cast<std::int64_t>(handle))
        ->setTempoRatio(ratio);
  } catch (...) {
    translateException(env, handle);
  }
}

extern "C" JNIEXPORT jfloatArray JNICALL
Java_com_homespotify_stretchpoc_HomeSpotifyStretchPocPlugin_00024NativeBindings_nativeProcess(
    JNIEnv *env, jobject /* receiver */, jlong handle, jfloatArray input,
    jint inputFrames, jint outputCapacityFrames) {
  try {
    if (input == nullptr) {
      throw std::invalid_argument("INVALID_ARGUMENT: PCM input array is null");
    }
    const auto engine =
        NativeEngineRegistry::instance().get(static_cast<std::int64_t>(handle));
    const std::size_t frameCount = checkedSize(inputFrames, "inputFrames");
    const std::size_t capacityFrames =
        checkedSize(outputCapacityFrames, "outputCapacityFrames");
    const jsize inputLength = env->GetArrayLength(input);
    std::vector<float> inputSamples(static_cast<std::size_t>(inputLength));
    env->GetFloatArrayRegion(input, 0, inputLength, inputSamples.data());
    if (env->ExceptionCheck()) {
      return nullptr;
    }

    const std::size_t channelCount =
        static_cast<std::size_t>(engine->channels());
    if (channelCount == 0 ||
        capacityFrames >
            std::numeric_limits<std::size_t>::max() / channelCount) {
      throw std::invalid_argument("INVALID_ARGUMENT: output capacity overflow");
    }
    std::vector<float> outputSamples(capacityFrames * channelCount);
    const std::size_t outputFrames = engine->process(
        inputSamples.data(), inputSamples.size(), frameCount,
        outputSamples.data(), outputSamples.size(), capacityFrames);
    outputSamples.resize(outputFrames * channelCount);

    if (outputSamples.size() >
        static_cast<std::size_t>(std::numeric_limits<jsize>::max())) {
      throw std::length_error(
          "BUFFER_TOO_SMALL: output exceeds the JNI array limit");
    }
    const jfloatArray result =
        env->NewFloatArray(static_cast<jsize>(outputSamples.size()));
    if (result == nullptr) {
      throw std::bad_alloc();
    }
    env->SetFloatArrayRegion(result, 0,
                             static_cast<jsize>(outputSamples.size()),
                             outputSamples.data());
    return result;
  } catch (...) {
    translateException(env, handle);
    return nullptr;
  }
}

extern "C" JNIEXPORT jfloatArray JNICALL
Java_com_homespotify_stretchpoc_HomeSpotifyStretchPocPlugin_00024NativeBindings_nativeFlush(
    JNIEnv *env, jobject /* receiver */, jlong handle,
    jint outputCapacityFrames) {
  try {
    const auto engine =
        NativeEngineRegistry::instance().get(static_cast<std::int64_t>(handle));
    const std::size_t capacityFrames =
        checkedSize(outputCapacityFrames, "outputCapacityFrames");
    const std::size_t channelCount =
        static_cast<std::size_t>(engine->channels());
    if (channelCount == 0 ||
        capacityFrames >
            std::numeric_limits<std::size_t>::max() / channelCount) {
      throw std::invalid_argument("INVALID_ARGUMENT: flush capacity overflow");
    }
    std::vector<float> outputSamples(capacityFrames * channelCount);
    const std::size_t outputFrames = engine->flush(
        outputSamples.data(), outputSamples.size(), capacityFrames);
    outputSamples.resize(outputFrames * channelCount);
    if (outputSamples.size() >
        static_cast<std::size_t>(std::numeric_limits<jsize>::max())) {
      throw std::length_error(
          "BUFFER_TOO_SMALL: flush output exceeds the JNI array limit");
    }
    const jfloatArray result =
        env->NewFloatArray(static_cast<jsize>(outputSamples.size()));
    if (result == nullptr) {
      throw std::bad_alloc();
    }
    env->SetFloatArrayRegion(result, 0,
                             static_cast<jsize>(outputSamples.size()),
                             outputSamples.data());
    return result;
  } catch (...) {
    translateException(env, handle);
    return nullptr;
  }
}

extern "C" JNIEXPORT void JNICALL
Java_com_homespotify_stretchpoc_HomeSpotifyStretchPocPlugin_00024NativeBindings_nativeReset(
    JNIEnv *env, jobject /* receiver */, jlong handle) {
  try {
    NativeEngineRegistry::instance()
        .get(static_cast<std::int64_t>(handle))
        ->reset();
  } catch (...) {
    translateException(env, handle);
  }
}

extern "C" JNIEXPORT jint JNICALL
Java_com_homespotify_stretchpoc_HomeSpotifyStretchPocPlugin_00024NativeBindings_nativeGetLatencyFrames(
    JNIEnv *env, jobject /* receiver */, jlong handle) {
  try {
    return static_cast<jint>(NativeEngineRegistry::instance()
                                 .get(static_cast<std::int64_t>(handle))
                                 ->getLatencyFrames());
  } catch (...) {
    translateException(env, handle);
    return 0;
  }
}

extern "C" JNIEXPORT jint JNICALL
Java_com_homespotify_stretchpoc_HomeSpotifyStretchPocPlugin_00024NativeBindings_nativeGetRequiredOutputFrames(
    JNIEnv *env, jobject /* receiver */, jlong handle, jint inputFrames) {
  try {
    const std::size_t required =
        NativeEngineRegistry::instance()
            .get(static_cast<std::int64_t>(handle))
            ->getRequiredOutputFrames(checkedSize(inputFrames, "inputFrames"));
    if (required > static_cast<std::size_t>(std::numeric_limits<jint>::max())) {
      throw std::overflow_error(
          "NATIVE_PROCESSING_FAILED: required output frame count overflow");
    }
    return static_cast<jint>(required);
  } catch (...) {
    translateException(env, handle);
    return 0;
  }
}

extern "C" JNIEXPORT jdouble JNICALL
Java_com_homespotify_stretchpoc_HomeSpotifyStretchPocPlugin_00024NativeBindings_nativeGetAppliedRatio(
    JNIEnv *env, jobject /* receiver */, jlong handle) {
  try {
    return NativeEngineRegistry::instance()
        .get(static_cast<std::int64_t>(handle))
        ->getAppliedRatio();
  } catch (...) {
    translateException(env, handle);
    return 1.0;
  }
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_homespotify_stretchpoc_HomeSpotifyStretchPocPlugin_00024NativeBindings_nativeGetEngineInfo(
    JNIEnv *env, jobject /* receiver */, jlong handle) {
  try {
    const std::string info = NativeEngineRegistry::instance()
                                 .get(static_cast<std::int64_t>(handle))
                                 ->getEngineInfo();
    return env->NewStringUTF(info.c_str());
  } catch (...) {
    translateException(env, handle);
    return nullptr;
  }
}

extern "C" JNIEXPORT void JNICALL
Java_com_homespotify_stretchpoc_HomeSpotifyStretchPocPlugin_00024NativeBindings_nativeDispose(
    JNIEnv * /* env */, jobject /* receiver */, jlong handle) {
  NativeEngineRegistry::instance().dispose(static_cast<std::int64_t>(handle));
}
