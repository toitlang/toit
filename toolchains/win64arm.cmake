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

# Note: mbedtls fails unless _MSC_VER is replaced with _WIN32 in line 198 of timimg.c

set(CMAKE_SYSTEM_NAME Windows)

set(triple armv7-w64-mingw32)
set(CMAKE_COMPILER_IS_CLANG 1)
set(_MSC_VER 1)

set(CMAKE_C_COMPILER armv7-w64-mingw32-gcc)
set(CMAKE_C_COMPILER_TARGET ${triple})
set(CMAKE_CXX_COMPILER armv7-w64-mingw32-g++)
set(CMAKE_CXX_COMPILER_TARGET ${triple})

set(CMAKE_ASM_FLAGS "${CMAKE_ASM_FLAGS} -m64 -x assembler-with-cpp" CACHE STRING "asm flags")
set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -m64 -Wno-error=sign-compare -DMBEDTLS_TIMING_ALT=1 -I${CMAKE_SOURCE_DIR}/src/ports" CACHE STRING "c flags")
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -m64 -DMBEDTLS_TIMING_ALT=1" CACHE STRING "c++ flags")

set(CMAKE_C_FLAGS_DEBUG "-Og -g" CACHE STRING "c Debug flags")
set(CMAKE_C_FLAGS_RELEASE "-Os" CACHE STRING "c Release flags")

set(CMAKE_CXX_FLAGS_DEBUG "-Og -g" CACHE STRING "c++ Debug flags")
set(CMAKE_CXX_FLAGS_RELEASE "-Os" CACHE STRING "c++ Release flags")

set(CMAKE_EXE_LINKER_FLAGS "-static-libgcc -static-libstdc++ -static")

set(TOIT_SYSTEM_NAME "${CMAKE_SYSTEM_NAME}")

set(GOOS "windows")
set(GOARCH "arm64")
