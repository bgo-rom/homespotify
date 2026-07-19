cmake_minimum_required(VERSION 3.18.1)

project(homespotify_stretch_poc LANGUAGES CXX)

option(HOMESPOTIFY_STRETCH_BUILD_NATIVE_TESTS "Build the lightweight host-native tests" OFF)

set(HOMESPOTIFY_STRETCH_VENDOR_DIR
    "${CMAKE_CURRENT_SOURCE_DIR}/third_party/signalsmith_stretch")
set(HOMESPOTIFY_STRETCH_HEADER
    "${HOMESPOTIFY_STRETCH_VENDOR_DIR}/signalsmith-stretch.h")
set(HOMESPOTIFY_LINEAR_STFT_HEADER
    "${HOMESPOTIFY_STRETCH_VENDOR_DIR}/signalsmith-linear/stft.h")
set(HOMESPOTIFY_LINEAR_FFT_HEADER
    "${HOMESPOTIFY_STRETCH_VENDOR_DIR}/signalsmith-linear/fft.h")
set(HOMESPOTIFY_STRETCH_LICENSE
    "${HOMESPOTIFY_STRETCH_VENDOR_DIR}/LICENSE.signalsmith-stretch.txt")
set(HOMESPOTIFY_LINEAR_LICENSE
    "${HOMESPOTIFY_STRETCH_VENDOR_DIR}/LICENSE.signalsmith-linear.txt")
set(HOMESPOTIFY_VENDOR_MANIFEST
    "${HOMESPOTIFY_STRETCH_VENDOR_DIR}/VENDOR_MANIFEST.json")

if(EXISTS "${HOMESPOTIFY_STRETCH_HEADER}"
   AND EXISTS "${HOMESPOTIFY_LINEAR_STFT_HEADER}"
   AND EXISTS "${HOMESPOTIFY_LINEAR_FFT_HEADER}"
   AND EXISTS "${HOMESPOTIFY_STRETCH_LICENSE}"
   AND EXISTS "${HOMESPOTIFY_LINEAR_LICENSE}"
   AND EXISTS "${HOMESPOTIFY_VENDOR_MANIFEST}")
  set(HOMESPOTIFY_STRETCH_HAS_SIGNALSMITH 1)
  message(STATUS "HomeSpotify Stretch: pinned Signalsmith vendor is available")
else()
  set(HOMESPOTIFY_STRETCH_HAS_SIGNALSMITH 0)
  message(WARNING
      "HomeSpotify Stretch: Signalsmith vendor is absent; building the safe unavailable fallback. "
      "Run tool/vendor_signalsmith.ps1 explicitly before DSP validation.")
endif()

set(HOMESPOTIFY_STRETCH_ENGINE_SOURCES
    homespotify_stretch/HomeSpotifyStretchEngine.cpp
    homespotify_stretch/NativeEngineRegistry.cpp)

add_library(homespotify_stretch_engine STATIC
    ${HOMESPOTIFY_STRETCH_ENGINE_SOURCES})
set_target_properties(homespotify_stretch_engine PROPERTIES
    POSITION_INDEPENDENT_CODE ON)

target_compile_features(homespotify_stretch_engine PUBLIC cxx_std_17)
target_compile_definitions(homespotify_stretch_engine
    PUBLIC HOMESPOTIFY_STRETCH_HAS_SIGNALSMITH=${HOMESPOTIFY_STRETCH_HAS_SIGNALSMITH})
target_include_directories(homespotify_stretch_engine
    PUBLIC
      "${CMAKE_CURRENT_SOURCE_DIR}/homespotify_stretch"
    PRIVATE
      "${HOMESPOTIFY_STRETCH_VENDOR_DIR}")

if(MSVC)
  target_compile_options(homespotify_stretch_engine PRIVATE /O2 /W4)
else()
  target_compile_options(homespotify_stretch_engine PRIVATE
      -O3 -Wall -Wextra -Wpedantic -fvisibility=hidden -fvisibility-inlines-hidden)
endif()

if(ANDROID)
  add_library(homespotify_stretch_poc SHARED
      homespotify_stretch/JniBridge.cpp)
  target_compile_features(homespotify_stretch_poc PRIVATE cxx_std_17)
  target_compile_options(homespotify_stretch_poc PRIVATE
      -O3 -Wall -Wextra -Wpedantic -fvisibility=hidden -fvisibility-inlines-hidden)
  target_link_options(homespotify_stretch_poc PRIVATE
      "-Wl,--exclude-libs,ALL" "-Wl,--gc-sections")
  target_link_libraries(homespotify_stretch_poc PRIVATE homespotify_stretch_engine)
endif()

if(HOMESPOTIFY_STRETCH_BUILD_NATIVE_TESTS AND NOT ANDROID)
  enable_testing()

  add_executable(homespotify_stretch_engine_test
      native_tests/engine_contract_test.cpp)
  target_link_libraries(homespotify_stretch_engine_test PRIVATE homespotify_stretch_engine)
  add_test(NAME homespotify_stretch_engine_test
      COMMAND homespotify_stretch_engine_test)

  add_executable(homespotify_stretch_fixture_compare
      native_tests/fixture_compare.cpp)
  target_link_libraries(homespotify_stretch_fixture_compare PRIVATE homespotify_stretch_engine)
endif()
