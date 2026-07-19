cmake_minimum_required(VERSION 3.18.1)

project(homespotify_stretch LANGUAGES CXX)

option(HOMESPOTIFY_STRETCH_BUILD_NATIVE_TESTS
       "Build the lightweight host-native engine contract test" OFF)

set(HOMESPOTIFY_STRETCH_VENDOR_DIR
    "${CMAKE_CURRENT_SOURCE_DIR}/third_party/signalsmith_stretch")
set(HOMESPOTIFY_REQUIRED_VENDOR_FILES
    "${HOMESPOTIFY_STRETCH_VENDOR_DIR}/signalsmith-stretch.h"
    "${HOMESPOTIFY_STRETCH_VENDOR_DIR}/signalsmith-linear/stft.h"
    "${HOMESPOTIFY_STRETCH_VENDOR_DIR}/signalsmith-linear/fft.h"
    "${HOMESPOTIFY_STRETCH_VENDOR_DIR}/LICENSE.signalsmith-stretch.txt"
    "${HOMESPOTIFY_STRETCH_VENDOR_DIR}/LICENSE.signalsmith-linear.txt"
    "${HOMESPOTIFY_STRETCH_VENDOR_DIR}/VENDOR_MANIFEST.json")

foreach(VENDOR_FILE IN LISTS HOMESPOTIFY_REQUIRED_VENDOR_FILES)
  if(NOT EXISTS "${VENDOR_FILE}")
    message(FATAL_ERROR
            "HomeSpotify Stretch production vendor is incomplete: ${VENDOR_FILE}")
  endif()
endforeach()

add_library(homespotify_stretch_engine STATIC
    homespotify_stretch/HomeSpotifyStretchEngine.cpp)
set_target_properties(homespotify_stretch_engine PROPERTIES
    POSITION_INDEPENDENT_CODE ON)
target_compile_features(homespotify_stretch_engine PUBLIC cxx_std_17)
target_compile_definitions(homespotify_stretch_engine
    PUBLIC HOMESPOTIFY_STRETCH_HAS_SIGNALSMITH=1)
target_include_directories(homespotify_stretch_engine
    PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/homespotify_stretch"
    PRIVATE "${HOMESPOTIFY_STRETCH_VENDOR_DIR}")

if(MSVC)
  target_compile_options(homespotify_stretch_engine PRIVATE /O2 /W4)
else()
  target_compile_options(homespotify_stretch_engine PRIVATE
      -O3
      -Wall
      -Wextra
      -Wpedantic
      -ffunction-sections
      -fdata-sections
      -fvisibility=hidden
      -fvisibility-inlines-hidden)
endif()

if(ANDROID)
  add_library(homespotify_stretch SHARED
      homespotify_stretch/JniBridge.cpp)
  target_compile_features(homespotify_stretch PRIVATE cxx_std_17)
  target_compile_options(homespotify_stretch PRIVATE
      -O3
      -Wall
      -Wextra
      -Wpedantic
      -ffunction-sections
      -fdata-sections
      -fvisibility=hidden
      -fvisibility-inlines-hidden)
  target_link_options(homespotify_stretch PRIVATE
      "-Wl,--exclude-libs,ALL"
      "-Wl,--gc-sections")
  target_link_libraries(homespotify_stretch PRIVATE
      homespotify_stretch_engine)
endif()

if(HOMESPOTIFY_STRETCH_BUILD_NATIVE_TESTS AND NOT ANDROID)
  enable_testing()
  add_executable(homespotify_stretch_engine_test
      native_tests/engine_contract_test.cpp)
  target_link_libraries(homespotify_stretch_engine_test PRIVATE
      homespotify_stretch_engine)
  add_test(NAME homespotify_stretch_engine_test
           COMMAND homespotify_stretch_engine_test)

  # Host-only calibration/listening bench; never packaged in the app.
  add_executable(homespotify_stretch_quality_lab
      native_tests/quality_lab.cpp)
  target_link_libraries(homespotify_stretch_quality_lab PRIVATE
      homespotify_stretch_engine)
endif()
