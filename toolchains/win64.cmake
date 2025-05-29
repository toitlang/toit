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

set(CMAKE_SYSTEM_NAME Windows CACHE STRING "The system name for the toolchain" FORCE)

set(triple x86_64-w64-mingw32)

set(CMAKE_C_COMPILER x86_64-w64-mingw32-gcc CACHE STRING "The C compiler for the toolchain")
set(CMAKE_C_COMPILER_TARGET ${triple} CACHE STRING "The target for the C compiler")
set(CMAKE_CXX_COMPILER x86_64-w64-mingw32-g++ CACHE STRING "The C++ compiler for the toolchain")
set(CMAKE_CXX_COMPILER_TARGET ${triple} CACHE STRING "The target for the C++ compiler")

set(CMAKE_ASM_FLAGS "${CMAKE_ASM_FLAGS} -m64 -x assembler-with-cpp" CACHE STRING "asm flags")
set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -m64 -Wno-error=sign-compare" CACHE STRING "c flags")
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -m64" CACHE STRING "c++ flags")

set(CMAKE_C_FLAGS_DEBUG "-Og -g" CACHE STRING "c Debug flags")
set(CMAKE_C_FLAGS_RELEASE "-Os" CACHE STRING "c Release flags")

set(CMAKE_CXX_FLAGS_DEBUG "-Og -g" CACHE STRING "c++ Debug flags")
set(CMAKE_CXX_FLAGS_RELEASE "-Os" CACHE STRING "c++ Release flags")

set(CMAKE_EXE_LINKER_FLAGS "-static-libgcc -static-libstdc++ -static" CACHE STRING "Linker flags for executables")

set(TOIT_SYSTEM_NAME "${CMAKE_SYSTEM_NAME}" CACHE STRING "The system name for the host toolchain")

set(GOOS "windows" CACHE STRING "The GOOS for the toolchain")
set(GOARCH "amd64" CACHE STRING "The GOARCH for the toolchain")
