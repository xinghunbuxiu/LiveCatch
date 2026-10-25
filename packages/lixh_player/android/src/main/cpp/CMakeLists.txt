cmake_minimum_required(VERSION 3.22.1)
project(lixh_player LANGUAGES C CXX)

get_filename_component(LIXH_PLUGIN_ANDROID "${CMAKE_CURRENT_SOURCE_DIR}" REALPATH)
# android/src/main/cpp → repo (6 levels)
get_filename_component(LIXH_REPO_ROOT "${LIXH_PLUGIN_ANDROID}/../../../../../.." ABSOLUTE)
if(NOT EXISTS "${LIXH_REPO_ROOT}/src-tauri/lixh-stream-stack/lixh-player-core/include/lixh_player.h")
  set(_probe "${CMAKE_CURRENT_SOURCE_DIR}")
  set(LIXH_REPO_ROOT "")
  foreach(_i RANGE 0 10)
    get_filename_component(_probe "${_probe}/.." ABSOLUTE)
    if(EXISTS "${_probe}/src-tauri/lixh-stream-stack/lixh-player-core/include/lixh_player.h")
      set(LIXH_REPO_ROOT "${_probe}")
      break()
    endif()
  endforeach()
endif()
if(LIXH_REPO_ROOT STREQUAL "")
  message(FATAL_ERROR "Cannot locate LiveCatch repo root from ${CMAKE_CURRENT_SOURCE_DIR}")
endif()

set(LIXH_CORE_DIR "${LIXH_REPO_ROOT}/src-tauri/lixh-stream-stack/lixh-player-core")

# Map Android ABI → LiveCatchFfmpeg platform id + jniLibs folder name.
if(ANDROID_ABI STREQUAL "armeabi-v7a")
  set(LIXH_FFMPEG_PLATFORM "android-armv7")
  set(LIXH_JNI_ABI "armeabi-v7a")
elseif(ANDROID_ABI STREQUAL "arm64-v8a")
  set(LIXH_FFMPEG_PLATFORM "android-arm64")
  set(LIXH_JNI_ABI "arm64-v8a")
else()
  message(FATAL_ERROR "Unsupported ANDROID_ABI=${ANDROID_ABI} (need arm64-v8a or armeabi-v7a)")
endif()

set(LIXH_FFMPEG_DIR "${LIXH_REPO_ROOT}/src-tauri/lixh-stream-stack/sdk/${LIXH_FFMPEG_PLATFORM}")
set(LIXH_RUNTIME_DIR "${LIXH_REPO_ROOT}/src-tauri/lixh-stream-stack/runtime/${LIXH_FFMPEG_PLATFORM}")

if(NOT EXISTS "${LIXH_FFMPEG_DIR}/include/libavcodec/avcodec.h")
  message(FATAL_ERROR
    "FFmpeg ${LIXH_FFMPEG_PLATFORM} SDK missing. Run:\n"
    "  bash src-tauri/lixh-stream-stack/scripts/fetch-ffmpeg-sdk.sh ${LIXH_FFMPEG_PLATFORM} "
    "src-tauri/lixh-stream-stack/sdk/${LIXH_FFMPEG_PLATFORM}")
endif()

function(lixh_find_so name outvar)
  # Release layout: sdk/lib/*.so and runtime/<abi>/*.so
  file(GLOB _cands
    "${LIXH_FFMPEG_DIR}/lib/lib${name}.so"
    "${LIXH_FFMPEG_DIR}/lib/${LIXH_JNI_ABI}/lib${name}.so"
    "${LIXH_RUNTIME_DIR}/${LIXH_JNI_ABI}/lib${name}.so"
    "${LIXH_RUNTIME_DIR}/lib${name}.so"
    "${LIXH_RUNTIME_DIR}/lib/lib${name}.so"
    "${LIXH_RUNTIME_DIR}/lib/${LIXH_JNI_ABI}/lib${name}.so"
  )
  if(NOT _cands)
    message(FATAL_ERROR "lib${name}.so not found under sdk/runtime ${LIXH_FFMPEG_PLATFORM}")
  endif()
  list(GET _cands 0 _path)
  set(${outvar} "${_path}" PARENT_SCOPE)
endfunction()

lixh_find_so(avcodec AVCODEC_SO)
lixh_find_so(avformat AVFORMAT_SO)
lixh_find_so(avutil AVUTIL_SO)
lixh_find_so(swresample SWRESAMPLE_SO)
lixh_find_so(swscale SWSCALE_SO)

add_library(avcodec SHARED IMPORTED)
set_target_properties(avcodec PROPERTIES IMPORTED_LOCATION "${AVCODEC_SO}")
add_library(avformat SHARED IMPORTED)
set_target_properties(avformat PROPERTIES IMPORTED_LOCATION "${AVFORMAT_SO}")
add_library(avutil SHARED IMPORTED)
set_target_properties(avutil PROPERTIES IMPORTED_LOCATION "${AVUTIL_SO}")
add_library(swresample SHARED IMPORTED)
set_target_properties(swresample PROPERTIES IMPORTED_LOCATION "${SWRESAMPLE_SO}")
add_library(swscale SHARED IMPORTED)
set_target_properties(swscale PROPERTIES IMPORTED_LOCATION "${SWSCALE_SO}")

add_library(lixh_player SHARED
  lixh_player_jni.cpp
  "${LIXH_CORE_DIR}/native/lixh_player.c"
)

target_compile_definitions(lixh_player PRIVATE LIXH_ANDROID)
target_compile_options(lixh_player PRIVATE
  $<$<COMPILE_LANGUAGE:C>:-std=c11>
  $<$<COMPILE_LANGUAGE:CXX>:-std=c++17>
  -pthread
)
target_link_options(lixh_player PRIVATE -pthread)
target_include_directories(lixh_player PRIVATE
  "${LIXH_CORE_DIR}/include"
  "${LIXH_FFMPEG_DIR}/include"
)

find_library(log-lib log)
find_library(mediandk-lib mediandk)
find_library(opensles-lib OpenSLES)
# libaaudio.so is dlopen'd at runtime (API 26+) so API 24–25 still load.
find_library(dl-lib dl)

target_link_libraries(lixh_player
  android
  ${log-lib}
  ${dl-lib}
  ${opensles-lib}
  ${mediandk-lib}
  avformat
  avcodec
  avutil
  swresample
  swscale
)
