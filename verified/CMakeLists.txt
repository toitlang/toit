# Copyright (C) 2026 Toit contributors.
#
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Lesser General Public
# License as published by the Free Software Foundation; version
# 2.1 only.
#
# This library is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# Lesser General Public License for more details.
#
# The license can be found in the file `LICENSE` in the top level
# directory of this repository.

# The Verus-verified interpreter core (verified/core).
#
# TOIT_VERIFIED_CORE (default ON for native 64-bit host builds, OFF for
# embedded and cross builds) links the core into toit_vm; it runs every
# format-2 program (src/interpreter_v2.cc). Without cargo the option is
# ignored with a warning, so the C++-only build keeps working (and refuses
# format-2 programs).
#
# Targets:
#   toit_verified_core         imported static library (built with cargo).
#   toit_verified_core_layout  runs the layout contract check; toit_vm
#                              depends on it, so a mismatch fails the build.
#   verified_core_verify       runs `cargo verus verify` (not part of ALL;
#                              also registered as a ctest when cargo-verus
#                              is available).

set(TOIT_VERIFIED_CORE_DEFAULT OFF)
if (NOT ${TOIT_IS_EMBEDDED} AND NOT ${TOIT_IS_CROSS} AND CMAKE_SIZEOF_VOID_P EQUAL 8)
  set(TOIT_VERIFIED_CORE_DEFAULT ON)
endif()
option(TOIT_VERIFIED_CORE "Run format-2 programs on the Verus-verified Rust core" ${TOIT_VERIFIED_CORE_DEFAULT})

set(TOIT_VERIFIED_CORE_ENABLED OFF CACHE INTERNAL "")
if (NOT TOIT_VERIFIED_CORE)
  return()
endif()

find_program(TOIT_CARGO cargo)
if (NOT TOIT_CARGO)
  message(WARNING "TOIT_VERIFIED_CORE is ON but cargo was not found; building without the verified core.")
  return()
endif()
set(TOIT_VERIFIED_CORE_ENABLED ON CACHE INTERNAL "")

set(VCORE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/core")
set(VCORE_TARGET_DIR "${CMAKE_BINARY_DIR}/verified_core")
set(VCORE_LIB "${VCORE_TARGET_DIR}/release/${CMAKE_STATIC_LIBRARY_PREFIX}toit_verified_core${CMAKE_STATIC_LIBRARY_SUFFIX}")
file(GLOB VCORE_SOURCES "${VCORE_DIR}/src/*.rs")

add_custom_command(
  OUTPUT "${VCORE_LIB}"
  COMMAND "${TOIT_CARGO}" build --release --quiet
          --manifest-path "${VCORE_DIR}/Cargo.toml"
          --target-dir "${VCORE_TARGET_DIR}"
  DEPENDS ${VCORE_SOURCES} "${VCORE_DIR}/Cargo.toml" "${VCORE_DIR}/Cargo.lock"
  WORKING_DIRECTORY "${VCORE_DIR}"
  COMMENT "Building the verified interpreter core (cargo)"
  USES_TERMINAL
  VERBATIM
)
add_custom_target(toit_verified_core_build DEPENDS "${VCORE_LIB}")

add_library(toit_verified_core STATIC IMPORTED GLOBAL)
# The core links Rust's std (the spec crate it is proven against uses it).
set_target_properties(toit_verified_core PROPERTIES
  IMPORTED_LOCATION "${VCORE_LIB}"
  INTERFACE_LINK_LIBRARIES "${CMAKE_DL_LIBS};pthread;m")
add_dependencies(toit_verified_core toit_verified_core_build)

# Layout contract: compares every constant the Rust side assumes against the
# C++ headers. Runs at build time (toit_vm depends on it) and as a ctest.
add_executable(toit_verified_core_layout_check layout_check.cc)
target_include_directories(toit_verified_core_layout_check PRIVATE "${TOIT_SDK_SOURCE_DIR}/src")
target_link_libraries(toit_verified_core_layout_check PRIVATE toit_verified_core)
set_target_properties(toit_verified_core_layout_check PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY "${VCORE_TARGET_DIR}")

set(VCORE_LAYOUT_STAMP "${VCORE_TARGET_DIR}/layout_check.stamp")
add_custom_command(
  OUTPUT "${VCORE_LAYOUT_STAMP}"
  COMMAND $<TARGET_FILE:toit_verified_core_layout_check>
  COMMAND ${CMAKE_COMMAND} -E touch "${VCORE_LAYOUT_STAMP}"
  DEPENDS toit_verified_core_layout_check
  COMMENT "Checking the verified core's layout contract"
  VERBATIM
)
add_custom_target(toit_verified_core_layout DEPENDS "${VCORE_LAYOUT_STAMP}")

add_test(
  NAME verified_core_layout
  COMMAND $<TARGET_FILE:toit_verified_core_layout_check>
)

find_program(TOIT_CARGO_VERUS cargo-verus)
add_custom_target(verified_core_verify
  COMMAND "${TOIT_CARGO}" verus verify --manifest-path "${VCORE_DIR}/Cargo.toml"
          --target-dir "${VCORE_TARGET_DIR}/verus"
  WORKING_DIRECTORY "${VCORE_DIR}"
  USES_TERMINAL
  VERBATIM
)
if (TOIT_CARGO_VERUS)
  add_test(
    NAME verified_core_verify
    COMMAND "${TOIT_CARGO}" verus verify --manifest-path "${VCORE_DIR}/Cargo.toml"
            --target-dir "${VCORE_TARGET_DIR}/verus"
    WORKING_DIRECTORY "${VCORE_DIR}"
  )
  set_tests_properties(verified_core_verify PROPERTIES TIMEOUT 600)
endif()
