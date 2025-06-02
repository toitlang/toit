# Copyright (C) 2019 Toitware ApS.
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

set(CMAKE_SYSTEM_NAME "Linux" CACHE STRING "The system name for the toolchain" FORCE)

set(CMAKE_C_COMPILER clang CACHE PATH "" FORCE)
set(CMAKE_CXX_COMPILER clang++ CACHE PATH "" FORCE)

set(TOIT_SYSTEM_NAME "${CMAKE_SYSTEM_NAME}" CACHE STRING "The system name for the host toolchain")

if ("${CMAKE_SYSROOT}" STREQUAL "")
  if (DEFINED ENV{SYSROOT})
    set(CMAKE_SYSROOT "$ENV{SYSROOT}" CACHE PATH "The sysroot for the toolchain")
  else()
    set(CMAKE_SYSROOT "${CMAKE_BINARY_DIR}/sysroot" CACHE PATH "The sysroot for the toolchain")
  endif()
endif()

if ("${ARM_TARGET}" STREQUAL "")
  if (DEFINED ENV{ARM_TARGET})
    set(ARM_TARGET "$ENV{ARM_TARGET}" CACHE STRING "The ARM target for the toolchain")
  else()
    # Typical targets are:
    # Barebone Linux:
    # - arm-linux-gnueabi: Linux ARM system without hardware floating point
    # Raspbian / Ubuntu:
    # - arm-linux-gnueabihf: Linux ARM system with hardware floating point
    # Arch Linux ARM:
    # - armv6l-unknown-linux-gnueabihf: Raspberry Pi 1.
    # - armv7l-unknown-linux-gnueabihf: Raspberry Pi 2, 3, 4.
    # - aarch64-unknown-linux-gnu: Archlinux ARM 64 bit.
    # Alpine:
    # - armv6-alpine-linux-musleabihf: Alpine Linux ARM 32 bit.
    # - aarch64-alpine-linux-musl: Alpine Linux ARM 64 bit.
    message(FATAL_ERROR, "Missing arm target")
  endif()
endif()

# Typical ARM_CPU_FLAGS are:
# Raspberry Pi 1: "-mcpu=arm1176jzf-s -mfpu=vfp"
# Raspberry Pi 2: "-mcpu=cortex-a7 -mfpu=neon-vfpv4 -mthumb"
# Raspberry Pi 3: "-mcpu=cortex-a53 -mfpu=neon-fp-armv8 -mthumb"
# Raspberry Pi 4: "-mcpu=cortex-a72 -mfpu=neon-fp-armv8 -mthumb"
# Raspberry Pi64: "-mcpu=cortex-a72"
set(CMAKE_ASM_FLAGS "${CMAKE_ASM_FLAGS} ${ARM_CPU_FLAGS}"
  CACHE STRING "asm flags for the ARM toolchain")
set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} ${ARM_CPU_FLAGS}"
  CACHE STRING "c flags for the ARM toolchain")
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} ${ARM_CPU_FLAGS}"
  CACHE STRING "c++ flags for the ARM toolchain")

set(CMAKE_C_COMPILER_TARGET "${ARM_TARGET}" CACHE STRING "c compiler target for the ARM toolchain")
set(CMAKE_CXX_COMPILER_TARGET "${ARM_TARGET}" CACHE STRING "c++ compiler target for the ARM toolchain")

set(CMAKE_ASM_FLAGS "${CMAKE_ASM_FLAGS} -x assembler-with-cpp" CACHE STRING "asm flags")

set(CMAKE_EXE_LINKER_FLAGS_INIT "${CMAKE_EXE_LINKER_FLAGS_INIT} -fuse-ld=lld"
  CACHE STRING "The linker flags for the toolchain" FORCE)

set(CMAKE_C_FLAGS_DEBUG "-Og -g -rdynamic -fdiagnostics-color" CACHE STRING "c Debug flags")
set(CMAKE_C_FLAGS_RELEASE "-Os" CACHE STRING "c Release flags")
set(CMAKE_C_FLAGS_ASAN "-O1 -fsanitize=address -fno-omit-frame-pointer -g" CACHE STRING "c Asan flags")
set(CMAKE_C_FLAGS_PROF "-Os -DPROF -pg" CACHE STRING "c Prof flags")

set(CMAKE_CXX_FLAGS_DEBUG "-Og -ggdb3 -rdynamic -fdiagnostics-color $ENV{LOCAL_CXXFLAGS}" CACHE STRING "c++ Debug flags")
set(CMAKE_CXX_FLAGS_RELEASE "-Os $ENV{LOCAL_CXXFLAGS}" CACHE STRING "c++ Release flags")
set(CMAKE_CXX_FLAGS_ASAN "-O1 -fsanitize=address -fno-omit-frame-pointer -g" CACHE STRING "c++ Asan flags")
set(CMAKE_CXX_FLAGS_PROF "-Os -DPROF -pg" CACHE STRING "c++ Prof flags")

set(CMAKE_EXE_LINKER_FLAGS_RELEASE "$ENV{LOCAL_LDFLAGS}" CACHE STRING "Linker flags for release builds")
