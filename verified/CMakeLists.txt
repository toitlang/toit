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
#   toit_verified_core         imported static library (built with cargo):
#                              verified/vmverify, which contains the core and
#                              the format-2 verifier (vmverify/README.md).
#   toit_verified_core_layout  runs the layout contract check; toit_vm
#                              depends on it, so a mismatch fails the build.
#   verified_core_verify       runs `cargo verus verify` (not part of ALL;
#                              also registered as a ctest when cargo-verus
#                              is available).

#   TOIT_VERIFIED_CORE_INFER   (default ON for hosts, OFF for embedded builds)
#                              links the certificate inference (vmverify
#                              `infer`); without it a format-2 program needs
#                              a shipped certificate.
#   TOIT_VERIFIED_CORE_RUST_TARGET  the Rust target triple the library is
#                              built for (empty: cargo's host target). Set
#                              automatically for 32-bit host builds
#                              (toolchains/host32.cmake: i686-unknown-linux-gnu);
#                              embedded targets set it in their toolchain
#                              (verified/core/PROGRESS.md, "Phase 5").

set(TOIT_VERIFIED_CORE_DEFAULT OFF)
set(TOIT_VERIFIED_CORE_RUST_TARGET_DEFAULT "")
if (NOT ${TOIT_IS_EMBEDDED} AND NOT ${TOIT_IS_CROSS})
  if (CMAKE_SIZEOF_VOID_P EQUAL 8)
    set(TOIT_VERIFIED_CORE_DEFAULT ON)
  elseif (CMAKE_SIZEOF_VOID_P EQUAL 4 AND "${CMAKE_SYSTEM_NAME}" STREQUAL "Linux"
          AND "${CMAKE_SYSTEM_PROCESSOR}" MATCHES "^(x86_64|AMD64|i[3-6]86)$")
    # -m32 builds on an x86 Linux host (toolchains/host32.cmake).
    set(TOIT_VERIFIED_CORE_DEFAULT ON)
    set(TOIT_VERIFIED_CORE_RUST_TARGET_DEFAULT "i686-unknown-linux-gnu")
  endif()
endif()
option(TOIT_VERIFIED_CORE "Run format-2 programs on the Verus-verified Rust core" ${TOIT_VERIFIED_CORE_DEFAULT})
set(TOIT_VERIFIED_CORE_RUST_TARGET "${TOIT_VERIFIED_CORE_RUST_TARGET_DEFAULT}" CACHE STRING
    "Rust target triple of the verified core (empty: the host)")
# The certificate inference (vmverify `infer`, verified/spec/format/
# 18-shipped-certificate.md): hosts infer a certificate for a format-2 program
# without a shipped one (and produce shipped certificates: toit.run
# --certify). Devices only check shipped certificates: without the option the
# inference is not linked and an untrusted program without a certificate is
# rejected.
if (${TOIT_IS_EMBEDDED})
  set(TOIT_VERIFIED_CORE_INFER_DEFAULT OFF)
else()
  set(TOIT_VERIFIED_CORE_INFER_DEFAULT ON)
endif()
option(TOIT_VERIFIED_CORE_INFER "Link the certificate inference (hosts)" ${TOIT_VERIFIED_CORE_INFER_DEFAULT})

set(TOIT_VERIFIED_CORE_ENABLED OFF CACHE INTERNAL "")
set(TOIT_VERIFIED_CORE_INFER_ENABLED OFF CACHE INTERNAL "")
if (NOT TOIT_VERIFIED_CORE)
  return()
endif()

find_program(TOIT_CARGO cargo)
if (NOT TOIT_CARGO)
  message(WARNING "TOIT_VERIFIED_CORE is ON but cargo was not found; building without the verified core.")
  return()
endif()
set(TOIT_VERIFIED_CORE_ENABLED ON CACHE INTERNAL "")
set(TOIT_VERIFIED_CORE_INFER_ENABLED ${TOIT_VERIFIED_CORE_INFER} CACHE INTERNAL "")

set(VCORE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/core")
# The VM links one Rust static library: verified/vmverify, which contains
# the core and the format-2 structural verifier (verified/spec), so that
# the binary has a single Rust runtime (vmverify/README.md).
set(VMVERIFY_DIR "${CMAKE_CURRENT_SOURCE_DIR}/vmverify")
set(VCORE_TARGET_DIR "${CMAKE_BINARY_DIR}/verified_core")
# Devices (embedded builds): no_std, the allocator and panic handler of the
# VM (vmverify `device-runtime`), Cargo profile `device` (panic = abort, LTO).
if (${TOIT_IS_EMBEDDED})
  set(VCORE_PROFILE device)
  set(VCORE_FEATURES device-runtime)
  set(TOIT_VERIFIED_CORE_OPT_LEVEL "3" CACHE STRING "Rust opt-level of the device library (3, s, z)")
  set(VCORE_ENV CARGO_PROFILE_DEVICE_OPT_LEVEL=${TOIT_VERIFIED_CORE_OPT_LEVEL})
  set(VCORE_LINK_LIBRARIES "m")
else()
  set(VCORE_PROFILE release)
  set(VCORE_FEATURES std)
  set(VCORE_ENV)
  # Hosts link Rust's std (panics of the verifier are caught: ffi.rs).
  set(VCORE_LINK_LIBRARIES "${CMAKE_DL_LIBS};pthread;m")
endif()
if ("${TOIT_VERIFIED_CORE_RUST_TARGET}" STREQUAL "")
  set(VCORE_CARGO_TARGET_ARGS)
  set(VCORE_LIB_DIR "${VCORE_TARGET_DIR}/${VCORE_PROFILE}")
else()
  set(VCORE_CARGO_TARGET_ARGS --target "${TOIT_VERIFIED_CORE_RUST_TARGET}")
  set(VCORE_LIB_DIR "${VCORE_TARGET_DIR}/${TOIT_VERIFIED_CORE_RUST_TARGET}/${VCORE_PROFILE}")
endif()
set(VCORE_LIB "${VCORE_LIB_DIR}/${CMAKE_STATIC_LIBRARY_PREFIX}toit_vmverify${CMAKE_STATIC_LIBRARY_SUFFIX}")
file(GLOB_RECURSE VCORE_SOURCES CONFIGURE_DEPENDS
  "${VCORE_DIR}/src/*.rs"
  "${VMVERIFY_DIR}/src/*.rs"
  "${CMAKE_CURRENT_SOURCE_DIR}/spec/src/*.rs")

if (TOIT_VERIFIED_CORE_INFER)
  list(APPEND VCORE_FEATURES infer)
endif()
list(JOIN VCORE_FEATURES "," VCORE_FEATURES_JOINED)
set(VCORE_FEATURE_ARGS --no-default-features --features "${VCORE_FEATURES_JOINED}")

add_custom_command(
  OUTPUT "${VCORE_LIB}"
  COMMAND ${CMAKE_COMMAND} -E env ${VCORE_ENV}
          "${TOIT_CARGO}" build --profile ${VCORE_PROFILE} --quiet --lib
          --manifest-path "${VMVERIFY_DIR}/Cargo.toml"
          --target-dir "${VCORE_TARGET_DIR}"
          ${VCORE_CARGO_TARGET_ARGS} ${VCORE_FEATURE_ARGS}
  DEPENDS ${VCORE_SOURCES}
          "${VCORE_DIR}/Cargo.toml" "${VMVERIFY_DIR}/Cargo.toml" "${VMVERIFY_DIR}/Cargo.lock"
          "${CMAKE_CURRENT_SOURCE_DIR}/spec/Cargo.toml"
  WORKING_DIRECTORY "${VMVERIFY_DIR}"
  COMMENT "Building the verified interpreter core and verifier (cargo)"
  USES_TERMINAL
  VERBATIM
)
add_custom_target(toit_verified_core_build DEPENDS "${VCORE_LIB}")

add_library(toit_verified_core STATIC IMPORTED GLOBAL)
set_target_properties(toit_verified_core PROPERTIES
  IMPORTED_LOCATION "${VCORE_LIB}"
  INTERFACE_LINK_LIBRARIES "${VCORE_LINK_LIBRARIES}")
add_dependencies(toit_verified_core toit_verified_core_build)

# Layout contract: compares every constant the Rust side assumes against the
# C++ headers. Runs at build time (toit_vm depends on it) and as a ctest.
# Not for embedded builds (the check cannot run on the build host): there
# the constants are those of the 32-bit host build, whose check covers
# them, and the FFI structs follow the target's C ABI on both sides
# (verified/core/PROGRESS.md, "Phase 5").
if (${TOIT_IS_EMBEDDED})
  return()
endif()
add_executable(toit_verified_core_layout_check layout_check.cc)
target_include_directories(toit_verified_core_layout_check PRIVATE "${TOIT_SDK_SOURCE_DIR}/src")
# The check uses only inline accessors of the headers; built as in a release
# build so that it does not need the VM's ASSERT support (debug and ASan
# builds).
target_compile_options(toit_verified_core_layout_check PRIVATE -UTOIT_DEBUG -DTOIT_DEPLOY)
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
