cmake_minimum_required(VERSION 3.14)

set(PROJECT_NAME "lixh_player")
project(${PROJECT_NAME} LANGUAGES C CXX)

cmake_policy(VERSION 3.14...3.25)

set(PLUGIN_NAME "lixh_player_plugin")

# Flutter installs the plugin via a symlink under windows/flutter/ephemeral —
# resolve the real package path so ../../.. is the monorepo root, not ephemeral/.
get_filename_component(LIXH_PLUGIN_WINDOWS "${CMAKE_CURRENT_SOURCE_DIR}" REALPATH)
get_filename_component(LIXH_REPO_ROOT "${LIXH_PLUGIN_WINDOWS}/../../.." ABSOLUTE)
if(NOT EXISTS "${LIXH_REPO_ROOT}/src-tauri/lixh-stream-stack/sdk/windows-x64")
  # Fallback: walk parents for the SDK marker (handles odd symlink layouts).
  set(_probe "${CMAKE_CURRENT_SOURCE_DIR}")
  set(LIXH_REPO_ROOT "")
  foreach(_i RANGE 0 8)
    get_filename_component(_probe "${_probe}/.." ABSOLUTE)
    if(EXISTS "${_probe}/src-tauri/lixh-stream-stack/sdk/windows-x64")
      set(LIXH_REPO_ROOT "${_probe}")
      break()
    endif()
  endforeach()
  if(LIXH_REPO_ROOT STREQUAL "")
    message(FATAL_ERROR "Cannot locate LiveCatch repo root (sdk/windows-x64 missing). CMAKE_CURRENT_SOURCE_DIR=${CMAKE_CURRENT_SOURCE_DIR}")
  endif()
endif()
message(STATUS "lixh_player: LIXH_REPO_ROOT=${LIXH_REPO_ROOT}")
set(LIXH_CORE_DIR "${LIXH_REPO_ROOT}/src-tauri/lixh-stream-stack/lixh-player-core")
set(LIXH_FFMPEG_DIR "${LIXH_REPO_ROOT}/src-tauri/lixh-stream-stack/sdk/windows-x64")
set(LIXH_RUNTIME_DIR "${LIXH_REPO_ROOT}/src-tauri/lixh-stream-stack/runtime/windows-x64")
set(LIXH_MSVC_IMPLIB_DIR "${CMAKE_CURRENT_BINARY_DIR}/ffmpeg_msvc_implib")

# MinGW ships .dll.a; Flutter Windows uses MSVC — build import libs from .def.
file(MAKE_DIRECTORY "${LIXH_MSVC_IMPLIB_DIR}")
find_program(LIXH_LIB_EXE NAMES lib lib.exe
  HINTS
    "$ENV{VCToolsInstallDir}/bin/Hostx64/x64"
    "C:/Program Files (x86)/Microsoft Visual Studio/2022/BuildTools/VC/Tools/MSVC/14.44.35207/bin/Hostx64/x64"
  REQUIRED)

# name.dll pairs for LIBRARY stamp + /OUT
set(_lixh_ffmpeg_pairs
  "avcodec-63|avcodec-63.dll"
  "avformat-63|avformat-63.dll"
  "avutil-61|avutil-61.dll"
  "swresample-7|swresample-7.dll"
)
foreach(_pair IN LISTS _lixh_ffmpeg_pairs)
  string(REPLACE "|" ";" _parts "${_pair}")
  list(GET _parts 0 _name)
  list(GET _parts 1 _dll)
  set(_src_def "${LIXH_FFMPEG_DIR}/lib/${_name}.def")
  set(_fixed_def "${LIXH_MSVC_IMPLIB_DIR}/${_name}.def")
  set(_lib "${LIXH_MSVC_IMPLIB_DIR}/${_name}.lib")
  if(NOT EXISTS "${_lib}" OR "${_src_def}" IS_NEWER_THAN "${_lib}")
    file(READ "${_src_def}" _def_body)
    file(WRITE "${_fixed_def}" "LIBRARY ${_dll}\n${_def_body}")
    execute_process(
      COMMAND "${LIXH_LIB_EXE}" "/DEF:${_fixed_def}" "/OUT:${_lib}" /MACHINE:X64
      RESULT_VARIABLE _lib_rc
      OUTPUT_VARIABLE _lib_out
      ERROR_VARIABLE _lib_err
    )
    if(NOT _lib_rc EQUAL 0)
      message(FATAL_ERROR "Failed to build ${_name}.lib: ${_lib_err}${_lib_out}")
    endif()
  endif()
endforeach()

list(APPEND PLUGIN_SOURCES
  "lixh_player_plugin.cpp"
  "lixh_player_plugin.h"
  "shared_texture.cpp"
  "shared_texture.h"
  "audio_output.cpp"
  "audio_output.h"
  "player_session.cpp"
  "player_session.h"
  "${LIXH_CORE_DIR}/native/lixh_player.c"
)

add_library(${PLUGIN_NAME} SHARED
  "include/lixh_player/lixh_player_plugin_c_api.h"
  "lixh_player_plugin_c_api.cpp"
  ${PLUGIN_SOURCES}
)

apply_standard_settings(${PLUGIN_NAME})
set_target_properties(${PLUGIN_NAME} PROPERTIES CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL LIXH_WINDOWS)
# /utf-8 avoids C4819 (code page 936) on FFmpeg headers / source comments.
target_compile_options(${PLUGIN_NAME} PRIVATE /utf-8 /wd4244)
# MSVC VS generator often drops COMPILE_LANGUAGE:C flags — stamp them on the .c file.
set_source_files_properties("${LIXH_CORE_DIR}/native/lixh_player.c" PROPERTIES
  LANGUAGE C
  COMPILE_OPTIONS "/std:c11;/experimental:c11atomics"
)

target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_include_directories(${PLUGIN_NAME} PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}"
  "${LIXH_CORE_DIR}/include"
  "${LIXH_FFMPEG_DIR}/include"
)

target_link_directories(${PLUGIN_NAME} PRIVATE "${LIXH_MSVC_IMPLIB_DIR}")
# Do NOT link swscale — MinGW swscale pulls libgcc_s_seh-1.dll.
target_link_libraries(${PLUGIN_NAME} PRIVATE
  flutter
  flutter_wrapper_plugin
  d3d11
  dxgi
  ole32
  avcodec-63
  avformat-63
  avutil-61
  swresample-7
)

# Ship FFmpeg runtime DLLs next to the app (no swscale — same as Tauri).
set(lixh_player_bundled_libraries
  "${LIXH_RUNTIME_DIR}/avcodec-63.dll"
  "${LIXH_RUNTIME_DIR}/avformat-63.dll"
  "${LIXH_RUNTIME_DIR}/avutil-61.dll"
  "${LIXH_RUNTIME_DIR}/swresample-7.dll"
  PARENT_SCOPE
)
