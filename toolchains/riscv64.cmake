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

set(CMAKE_C_COMPILER clang CACHE PATH "" FORCE)
set(CMAKE_CXX_COMPILER clang++ CACHE PATH "" FORCE)

set(CMAKE_SYSTEM_NAME Linux CACHE STRING "The system name for the toolchain" FORCE)
set(CMAKE_SYSTEM_PROCESSOR riscv64 CACHE STRING "The system processor for the toolchain" FORCE)

set(TOIT_SYSTEM_NAME "${CMAKE_SYSTEM_NAME}" CACHE STRING "The system name for the host toolchain")

if ("${CMAKE_SYSROOT}" STREQUAL "")
  if (DEFINED ENV{SYSROOT})
    set(CMAKE_SYSROOT "$ENV{SYSROOT}" CACHE PATH "The sysroot for the toolchain")
  else()
    set(CMAKE_SYSROOT "${CMAKE_BINARY_DIR}/sysroot" CACHE PATH "The sysroot for the toolchain")
  endif()
endif()

set(CMAKE_C_COMPILER_TARGET "riscv64-linux-gnu" CACHE STRING "c compiler target")
set(CMAKE_CXX_COMPILER_TARGET "riscv64-linux-gnu" CACHE STRING "c++ compiler target")


set(CMAKE_ASM_FLAGS "${CMAKE_ASM_FLAGS} -x assembler-with-cpp" CACHE STRING "asm flags")
set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS}" CACHE STRING "c flags")
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS}" CACHE STRING "c++ flags")

set(CMAKE_EXE_LINKER_FLAGS_INIT "${CMAKE_EXE_LINKER_FLAGS_INIT} -fuse-ld=lld" CACHE STRING "Linker flags for executables")

set(CMAKE_C_FLAGS_DEBUG "-Og -g -rdynamic -fdiagnostics-color" CACHE STRING "c Debug flags")
set(CMAKE_C_FLAGS_RELEASE "-Os" CACHE STRING "c Release flags")
set(CMAKE_C_FLAGS_ASAN "-O1 -fsanitize=address -fno-omit-frame-pointer -g" CACHE STRING "c Asan flags")
set(CMAKE_C_FLAGS_PROF "-Os -DPROF -pg" CACHE STRING "c Prof flags")

set(CMAKE_CXX_FLAGS_DEBUG "-Og -ggdb3 -rdynamic -fdiagnostics-color $ENV{LOCAL_CXXFLAGS}" CACHE STRING "c++ Debug flags")
set(CMAKE_CXX_FLAGS_RELEASE "-Os $ENV{LOCAL_CXXFLAGS}" CACHE STRING "c++ Release flags")
set(CMAKE_CXX_FLAGS_ASAN "-O1 -fsanitize=address -fno-omit-frame-pointer -g" CACHE STRING "c++ Asan flags")
set(CMAKE_CXX_FLAGS_PROF "-Os -DPROF -pg" CACHE STRING "c++ Prof flags")

set(FIND_LIBRARY_USE_LIB64_PATHS OFF)

set(GOOS "linux" CACHE STRING "The GOOS for the toolchain")
set(GOARCH "riscv64" CACHE STRING "The GOARCH for the toolchain")

enable_testing()
