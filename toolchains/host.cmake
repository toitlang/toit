# Copyright (C) 2022 Toitware ApS.
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

set(TOIT_SYSTEM_NAME "${CMAKE_SYSTEM_NAME}" CACHE STRING "The system name for the host toolchain")

set(CMAKE_OSX_ARCHITECTURES "x86_64;arm64" CACHE STRING "Build architectures for Mac OS X" FORCE)

set(CMAKE_C_FLAGS_DEBUG "-O1 -g $ENV{LOCAL_CFLAGS}" CACHE STRING "c Debug flags")
set(CMAKE_CXX_FLAGS_DEBUG "-O1 -ggdb3 -fdiagnostics-color $ENV{LOCAL_CXXFLAGS}" CACHE STRING "c++ Debug flags")
set(CMAKE_C_FLAGS_RELEASE "-Os $ENV{LOCAL_CFLAGS}" CACHE STRING "c Release flags")
set(CMAKE_CXX_FLAGS_RELEASE "-Os $ENV{LOCAL_CXXFLAGS}" CACHE STRING "c++ Release flags")
set(CMAKE_EXE_LINKER_FLAGS_RELEASE "$ENV{LOCAL_LDFLAGS}" CACHE STRING "Linker flags for release builds")

enable_testing()
