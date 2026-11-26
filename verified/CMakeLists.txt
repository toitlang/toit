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
# format-2 programs, and so every untrusted container: untrusted programs
# must be in format 2).
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
#   TOIT_VERIFIED_CORE_CHECKED_LOOP  (default ON for hosts, OFF for embedded
#                              builds) links the core's checked loop; without
#                              it only verified format-2 programs run.
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
# The Xtensa chips have no upstream Rust target: the Toit fork of the esp-rs
# toolchain (`cargo +toit-esp`, docs/xtensa-rust-toolchain.md) builds `core`
# and `alloc` from source (-Zbuild-std); toolchains/idf/components/toit sets
# both values.
set(TOIT_VERIFIED_CORE_CARGO_TOOLCHAIN "" CACHE STRING
    "rustup toolchain for the verified core, with the plus (empty: the default)")
set(TOIT_VERIFIED_CORE_CARGO_ARGS "" CACHE STRING
    "Extra cargo arguments for the verified core (a CMake list)")
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
# The core's checked loop (core and vmverify `checked-loop`): runs format-2
# programs the verifier did not accept (trusted programs started without
# -Xverify). Devices run format 2 only for verified untrusted programs
# (ProcessGroup::create refuses the others) and do not link it.
option(TOIT_VERIFIED_CORE_CHECKED_LOOP "Link the checked run loop of the core (hosts)" ${TOIT_VERIFIED_CORE_INFER_DEFAULT})

# Sandboxed (untrusted) containers (docs/sandbox-policy.md, "Firmware without
# sandboxes"): the format-2 verifier for their installs and launches
# (vmverify's toit_vmverify_verify and verified/spec's checker, about 35 KB
# of flash on the classic ESP32), the untrusted policy's primitive tables,
# and the C++ that only sandboxed processes reach. Off, the VM refuses every
# untrusted install and launch (SANDBOX_NOT_SUPPORTED), the linker drops
# the Rust verifier, and trusted programs run as before on the same core.
# On by default for hosts (the SDK makes the certificates of untrusted
# programs and runs the sandbox tests); devices take it from Kconfig
# TOIT_SANDBOX (default off). Needs the verified core: without it there are
# no sandboxes either.
option(TOIT_SANDBOX "Support sandboxed (untrusted) containers" ON)

set(TOIT_VERIFIED_CORE_ENABLED OFF CACHE INTERNAL "")
set(TOIT_SANDBOX_ENABLED OFF CACHE INTERNAL "")
set(TOIT_VERIFIED_CORE_INFER_ENABLED OFF CACHE INTERNAL "")
set(TOIT_VERIFIED_CORE_CHECKED_LOOP_ENABLED OFF CACHE INTERNAL "")
if (NOT TOIT_VERIFIED_CORE)
  return()
endif()

find_program(TOIT_CARGO cargo)
if (NOT TOIT_CARGO)
  message(WARNING "TOIT_VERIFIED_CORE is ON but cargo was not found; building without the verified core: "
                  "this VM refuses every format-2 program and every untrusted container.")
  return()
endif()
set(TOIT_VERIFIED_CORE_ENABLED ON CACHE INTERNAL "")
set(TOIT_SANDBOX_ENABLED ${TOIT_SANDBOX} CACHE INTERNAL "")
set(TOIT_VERIFIED_CORE_INFER_ENABLED ${TOIT_VERIFIED_CORE_INFER} CACHE INTERNAL "")
set(TOIT_VERIFIED_CORE_CHECKED_LOOP_ENABLED ${TOIT_VERIFIED_CORE_CHECKED_LOOP} CACHE INTERNAL "")

# The verified/ sources the Rust library is built from: this directory, or
# a patched copy for measurements (verified/vmverify/README.md, "Device
# size").
set(TOIT_VERIFIED_CORE_SOURCE_DIR "${CMAKE_CURRENT_SOURCE_DIR}" CACHE PATH "The verified/ sources of the Rust library")
set(VCORE_DIR "${TOIT_VERIFIED_CORE_SOURCE_DIR}/core")
# The VM links one Rust static library: verified/vmverify, which contains
# the core and the format-2 structural verifier (verified/spec), so that
# the binary has a single Rust runtime (vmverify/README.md). It is built
# through the staticlib-only package vmverify/staticlib (libtoit_rust.a):
# Cargo applies the device profile's LTO only to a library that is not also
# an rlib.
set(VMVERIFY_DIR "${TOIT_VERIFIED_CORE_SOURCE_DIR}/vmverify")
set(VMLIB_DIR "${VMVERIFY_DIR}/staticlib")
set(VCORE_TARGET_DIR "${CMAKE_BINARY_DIR}/verified_core")
# Devices (embedded builds): no_std, the allocator and panic handler of the
# VM (vmverify `device-runtime`), Cargo profile `device` (panic = abort, LTO).
if (${TOIT_IS_EMBEDDED})
  set(VCORE_PROFILE device)
  set(VCORE_FEATURES device-runtime)
  set(TOIT_VERIFIED_CORE_OPT_LEVEL "3" CACHE STRING "Rust opt-level of the device library (3, s, z)")
  set(VCORE_ENV CARGO_PROFILE_DEVICE_OPT_LEVEL=${TOIT_VERIFIED_CORE_OPT_LEVEL})
  # The verifier and the spec functions it runs (Cargo packages toit_vmverify
  # and toit_spec) have their own opt-level (Cargo.toml: z, for size); a
  # value here overrides it (Kconfig TOIT_VERIFIED_CORE_VERIFIER_OPT_LEVEL).
  set(TOIT_VERIFIED_CORE_VERIFIER_OPT_LEVEL "" CACHE STRING "Rust opt-level of the verifier on devices (empty: Cargo.toml)")
  set(VCORE_PROFILE_ARGS)
  if (TOIT_VERIFIED_CORE_VERIFIER_OPT_LEVEL)
    set(level "${TOIT_VERIFIED_CORE_VERIFIER_OPT_LEVEL}")
    if (NOT level MATCHES "^[0-3]$")
      set(level "\"${level}\"")
    endif()
    list(APPEND VCORE_PROFILE_ARGS
         --config "profile.device.package.toit_vmverify.opt-level=${level}"
         --config "profile.device.package.toit_spec.opt-level=${level}")
  endif()
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
set(VCORE_LIB "${VCORE_LIB_DIR}/${CMAKE_STATIC_LIBRARY_PREFIX}toit_rust${CMAKE_STATIC_LIBRARY_SUFFIX}")
file(GLOB_RECURSE VCORE_SOURCES CONFIGURE_DEPENDS
  "${VCORE_DIR}/src/*.rs"
  "${VMVERIFY_DIR}/src/*.rs"
  "${TOIT_VERIFIED_CORE_SOURCE_DIR}/spec/src/*.rs")

if (TOIT_VERIFIED_CORE_INFER)
  list(APPEND VCORE_FEATURES infer)
endif()
if (TOIT_VERIFIED_CORE_CHECKED_LOOP)
  list(APPEND VCORE_FEATURES checked-loop)
endif()
# -Xpreempt_a_lot exists in debug VM builds only (TOIT_DEBUG, src/flags.h);
# release builds leave the test out, as the C++ interpreter's.
if (CMAKE_BUILD_TYPE MATCHES "^(Debug|Asan|ASan|ASAN)$")
  list(APPEND VCORE_FEATURES preempt-a-lot)
endif()
# The run loop split into a hot part and an out-of-line cold part
# (step::step_cold; core feature `split-loop`): for devices whose hot part
# goes to a small IRAM (Kconfig TOIT_VERIFIED_CORE_SPLIT_LOOP: the classic
# ESP32). Off: one loop with every handler, no step_cold in the binary.
option(TOIT_VERIFIED_CORE_SPLIT_LOOP "Split the core's run loop into a hot and a cold part" OFF)
if (TOIT_VERIFIED_CORE_SPLIT_LOOP)
  list(APPEND VCORE_FEATURES split-loop)
endif()
list(JOIN VCORE_FEATURES "," VCORE_FEATURES_JOINED)
set(VCORE_FEATURE_ARGS --no-default-features --features "${VCORE_FEATURES_JOINED}")

add_custom_command(
  OUTPUT "${VCORE_LIB}"
  COMMAND ${CMAKE_COMMAND} -E env ${VCORE_ENV}
          "${TOIT_CARGO}" ${TOIT_VERIFIED_CORE_CARGO_TOOLCHAIN} build --profile ${VCORE_PROFILE} --quiet --lib
          --manifest-path "${VMLIB_DIR}/Cargo.toml"
          --target-dir "${VCORE_TARGET_DIR}"
          ${VCORE_CARGO_TARGET_ARGS} ${VCORE_FEATURE_ARGS} ${TOIT_VERIFIED_CORE_CARGO_ARGS} ${VCORE_PROFILE_ARGS}
  DEPENDS ${VCORE_SOURCES}
          "${VCORE_DIR}/Cargo.toml" "${VMVERIFY_DIR}/Cargo.toml" "${VMLIB_DIR}/Cargo.toml"
          "${VMLIB_DIR}/Cargo.lock" "${VMLIB_DIR}/lib.rs" "${VMVERIFY_DIR}/.cargo/config.toml"
          "${TOIT_VERIFIED_CORE_SOURCE_DIR}/spec/Cargo.toml"
  WORKING_DIRECTORY "${VMLIB_DIR}"
  COMMENT "Building the verified interpreter core and verifier (cargo)"
  USES_TERMINAL
  VERBATIM
)
set(VCORE_LINKED_LIB "${VCORE_LIB}")
if (${TOIT_IS_EMBEDDED})
  # The firmware links newlib's libm, not compiler_builtins' copy of the C
  # math functions (vmverify/staticlib/localize-libm.cmake).
  # With TOIT_VERIFIED_CORE_LOOP_IN_IRAM the same step moves the run loop
  # into IRAM (Kconfig TOIT_VERIFIED_CORE_LOOP_IN_IRAM).
  option(TOIT_VERIFIED_CORE_LOOP_IN_IRAM "Place the core's run loop in IRAM (ESP32 targets)" OFF)
  # More functions of the library for IRAM (localize-libm.cmake, IRAM_FUNCTIONS;
  # Kconfig TOIT_VERIFIED_CORE_IRAM_FUNCTIONS): a comma-separated list.
  set(TOIT_VERIFIED_CORE_IRAM_FUNCTIONS "" CACHE STRING "Functions of the core library for IRAM (ESP32 targets)")
  # Rerun the step when the placement changes.
  set(VCORE_PLACEMENT_STAMP "${CMAKE_CURRENT_BINARY_DIR}/vcore-placement.txt")
  file(CONFIGURE OUTPUT "${VCORE_PLACEMENT_STAMP}"
       CONTENT "loop-in-iram=${TOIT_VERIFIED_CORE_LOOP_IN_IRAM} iram-functions=${TOIT_VERIFIED_CORE_IRAM_FUNCTIONS}\n")
  set(VCORE_LINKED_LIB "${VCORE_LIB_DIR}/${CMAKE_STATIC_LIBRARY_PREFIX}toit_rust_device${CMAKE_STATIC_LIBRARY_SUFFIX}")
  add_custom_command(
    OUTPUT "${VCORE_LINKED_LIB}"
    COMMAND ${CMAKE_COMMAND} -DNM=${CMAKE_NM} -DOBJCOPY=${CMAKE_OBJCOPY}
            -DOBJDUMP=${CMAKE_OBJDUMP} -DLOOP_IN_IRAM=${TOIT_VERIFIED_CORE_LOOP_IN_IRAM}
            "-DIRAM_FUNCTIONS=${TOIT_VERIFIED_CORE_IRAM_FUNCTIONS}"
            -DINPUT=${VCORE_LIB} -DOUTPUT=${VCORE_LINKED_LIB}
            -P "${VMLIB_DIR}/localize-libm.cmake"
    DEPENDS "${VCORE_LIB}" "${VMLIB_DIR}/localize-libm.cmake" "${VCORE_PLACEMENT_STAMP}"
    COMMENT "Localizing the C math functions of the Rust library"
    VERBATIM
  )
endif()
add_custom_target(toit_verified_core_build DEPENDS "${VCORE_LINKED_LIB}")

add_library(toit_verified_core STATIC IMPORTED GLOBAL)
set_target_properties(toit_verified_core PROPERTIES
  IMPORTED_LOCATION "${VCORE_LINKED_LIB}"
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
