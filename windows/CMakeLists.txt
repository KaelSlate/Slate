# Project-level configuration.
cmake_minimum_required(VERSION 3.14)
project(slate LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "slate")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# Define build configuration option.
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()
# Define settings for the Profile build mode.
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd"4100")
  target_compile_options(${TARGET} PRIVATE /EHsc)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

# ═══════════════════════════════════════════════════════════════════════════════
# AUTO-HEAL: Regenerate missing Flutter ephemeral wrapper sources.
#
# The cpp_client_wrapper .cc files in windows/flutter/ephemeral/ sometimes
# vanish (flaky tooling issue). When that happens, the MSVC build explodes
# with C1083 "cannot open source file". This block detects the problem at
# CMake-configure time and fixes it automatically before anything tries to
# compile.
# ═══════════════════════════════════════════════════════════════════════════════
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
set(_EPHEMERAL_DIR "${FLUTTER_MANAGED_DIR}/ephemeral")
set(_WRAPPER_SENTINEL "${_EPHEMERAL_DIR}/cpp_client_wrapper/core_implementations.cc")
set(_CONFIG_SENTINEL "${_EPHEMERAL_DIR}/generated_config.cmake")

if(NOT EXISTS "${_WRAPPER_SENTINEL}")
  message(WARNING
    "[AUTO-HEAL] Flutter ephemeral wrapper sources are missing!\n"
    "  Missing: ${_WRAPPER_SENTINEL}\n"
    "  Attempting automatic recovery...")

  # ── Resolve FLUTTER_ROOT ──────────────────────────────────────────────────
  # Most common case: only cpp_client_wrapper/ vanished, but
  # generated_config.cmake is still intact — parse FLUTTER_ROOT from it.
  set(_HEAL_FLUTTER_ROOT "")
  if(EXISTS "${_CONFIG_SENTINEL}")
    file(READ "${_CONFIG_SENTINEL}" _GEN_CONFIG_CONTENTS)
    string(REGEX MATCH "TO_CMAKE_PATH \"([^\"]+)\" FLUTTER_ROOT" _MATCH "${_GEN_CONFIG_CONTENTS}")
    set(_HEAL_FLUTTER_ROOT "${CMAKE_MATCH_1}")
    string(REPLACE "\\\\" "/" _HEAL_FLUTTER_ROOT "${_HEAL_FLUTTER_ROOT}")
  endif()

  # Fallback: try to find flutter in PATH
  if(NOT _HEAL_FLUTTER_ROOT)
    find_program(_HEAL_FLUTTER_BIN flutter)
    if(_HEAL_FLUTTER_BIN)
      # flutter binary is at <root>/bin/flutter — go two levels up
      get_filename_component(_HEAL_FLUTTER_ROOT "${_HEAL_FLUTTER_BIN}" DIRECTORY)
      get_filename_component(_HEAL_FLUTTER_ROOT "${_HEAL_FLUTTER_ROOT}" DIRECTORY)
    endif()
  endif()

  if(NOT _HEAL_FLUTTER_ROOT)
    message(FATAL_ERROR
      "[AUTO-HEAL] Cannot determine FLUTTER_ROOT.\n"
      "  generated_config.cmake is missing and 'flutter' is not in PATH.\n"
      "  Manual fix: flutter clean && flutter pub get && flutter build windows")
  endif()

  set(_FLUTTER_BIN "${_HEAL_FLUTTER_ROOT}/bin/flutter.bat")
  message(STATUS "[AUTO-HEAL] FLUTTER_ROOT = ${_HEAL_FLUTTER_ROOT}")

  # ── Step 1: flutter pub get ───────────────────────────────────────────────
  # Restores generated_config.cmake (if absent) and plugin symlinks.
  message(STATUS "[AUTO-HEAL] Running 'flutter pub get'...")
  execute_process(
    COMMAND "${_FLUTTER_BIN}" pub get
    WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/.."
    RESULT_VARIABLE _PUB_GET_RESULT
    OUTPUT_VARIABLE _PUB_GET_OUTPUT
    ERROR_VARIABLE  _PUB_GET_ERROR
  )
  if(NOT _PUB_GET_RESULT EQUAL 0)
    message(WARNING "[AUTO-HEAL] 'flutter pub get' returned ${_PUB_GET_RESULT}: ${_PUB_GET_ERROR}")
  else()
    message(STATUS "[AUTO-HEAL] 'flutter pub get' succeeded.")
  endif()

  # ── Step 2: tool_backend.bat ──────────────────────────────────────────────
  # Regenerates the actual .cc wrapper sources + flutter_windows.dll.
  set(_TOOL_BACKEND "${_HEAL_FLUTTER_ROOT}/packages/flutter_tools/bin/tool_backend.bat")
  if(EXISTS "${_TOOL_BACKEND}")
    # Determine build mode — default to Debug during configure
    if(NOT CMAKE_BUILD_TYPE)
      set(_HEAL_BUILD_MODE "Debug")
    else()
      set(_HEAL_BUILD_MODE "${CMAKE_BUILD_TYPE}")
    endif()

    message(STATUS "[AUTO-HEAL] Running tool_backend.bat (${_HEAL_BUILD_MODE})...")
    execute_process(
      COMMAND ${CMAKE_COMMAND} -E env
        "FLUTTER_ROOT=${_HEAL_FLUTTER_ROOT}"
        "PROJECT_DIR=${CMAKE_CURRENT_SOURCE_DIR}/.."
        "FLUTTER_EPHEMERAL_DIR=${_EPHEMERAL_DIR}"
        "FLUTTER_TARGET=lib/main.dart"
        "${_TOOL_BACKEND}"
        windows-x64 ${_HEAL_BUILD_MODE}
      WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/.."
      RESULT_VARIABLE _TB_RESULT
      OUTPUT_VARIABLE _TB_OUTPUT
      ERROR_VARIABLE  _TB_ERROR
    )
    if(NOT _TB_RESULT EQUAL 0)
      message(WARNING "[AUTO-HEAL] tool_backend.bat returned ${_TB_RESULT}: ${_TB_ERROR}")
    else()
      message(STATUS "[AUTO-HEAL] tool_backend.bat succeeded — wrapper sources restored.")
    endif()
  else()
    message(WARNING
      "[AUTO-HEAL] tool_backend.bat not found at ${_TOOL_BACKEND}")
  endif()

  # ── Final gate ────────────────────────────────────────────────────────────
  if(NOT EXISTS "${_WRAPPER_SENTINEL}")
    message(FATAL_ERROR
      "[AUTO-HEAL] Recovery failed — wrapper sources still missing.\n"
      "  Expected: ${_WRAPPER_SENTINEL}\n"
      "  Manual fix: flutter clean && flutter pub get && flutter build windows")
  else()
    message(STATUS "[AUTO-HEAL] Recovery complete. Continuing build.")
  endif()
endif()

# Flutter library and tool build rules.
add_subdirectory(${FLUTTER_MANAGED_DIR})

# ── AUTO-HEAL, build-time belt ───────────────────────────────────────────────
# The configure-time block above can't help when configure is SKIPPED
# (incremental builds) and the files vanish between builds: the flutter
# tool's unpack recopies cpp_client_wrapper on every build, and clangd
# holding the .cc files makes that recopy come back include-only. This runs
# on EVERY build right before the wrapper targets compile (after the unpack)
# and restores stragglers straight from the engine cache. See heal_wrapper.cmake.
# Parse FLUTTER_ROOT out of the file instead of include()-ing it: its version
# set()s use PARENT_SCOPE, which has no parent at this top-level scope and
# spams five dev warnings on every configure.
if(EXISTS "${_CONFIG_SENTINEL}")
  file(STRINGS "${_CONFIG_SENTINEL}" _FLUTTER_ROOT_LINE
       REGEX "TO_CMAKE_PATH .* FLUTTER_ROOT")
  if(_FLUTTER_ROOT_LINE MATCHES "TO_CMAKE_PATH \"([^\"]+)\" FLUTTER_ROOT")
    file(TO_CMAKE_PATH "${CMAKE_MATCH_1}" FLUTTER_ROOT)
    # The generated line escapes backslashes; collapse the doubled slashes.
    string(REGEX REPLACE "/+" "/" FLUTTER_ROOT "${FLUTTER_ROOT}")
  endif()
endif()
if(DEFINED FLUTTER_ROOT)
  set(_WRAPPER_CACHE_DIR
      "${FLUTTER_ROOT}/bin/cache/artifacts/engine/windows-x64/cpp_client_wrapper")
  # Runs every build. Ordering chain: flutter_assemble (the unpack that can
  # lose the files) -> wrapper_heal -> wrapper compile targets.
  add_custom_target(wrapper_heal
    COMMAND ${CMAKE_COMMAND}
      -DSRC=${_WRAPPER_CACHE_DIR}
      -DDST=${_EPHEMERAL_DIR}/cpp_client_wrapper
      -P "${CMAKE_CURRENT_SOURCE_DIR}/heal_wrapper.cmake"
    COMMENT "[AUTO-HEAL] wrapper sources presence check")
  if(TARGET flutter_assemble)
    add_dependencies(wrapper_heal flutter_assemble)
  endif()
  foreach(_wrapper_target flutter_wrapper_app flutter_wrapper_plugin)
    if(TARGET ${_wrapper_target})
      add_dependencies(${_wrapper_target} wrapper_heal)
    endif()
  endforeach()
endif()

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)


# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/windows/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)
