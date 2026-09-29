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

# Toolchain file for WebAssembly, compiled with Emscripten.
#
# Emscripten is found through the EMSCRIPTEN environment variable, or by
# looking for 'emcc' in the PATH.

if (DEFINED ENV{EMSCRIPTEN})
  set(TOIT_EMSCRIPTEN_ROOT "$ENV{EMSCRIPTEN}")
else()
  find_program(TOIT_EMCC emcc)
  if (NOT TOIT_EMCC)
    message(FATAL_ERROR "Could not find emcc. Install Emscripten, or set the EMSCRIPTEN environment variable.")
  endif()
  get_filename_component(TOIT_EMCC "${TOIT_EMCC}" REALPATH)
  get_filename_component(TOIT_EMSCRIPTEN_ROOT "${TOIT_EMCC}" DIRECTORY)
endif()

include("${TOIT_EMSCRIPTEN_ROOT}/cmake/Modules/Platform/Emscripten.cmake")

set(TOIT_SYSTEM_NAME "wasm" CACHE STRING "The Toit system name")

set(CMAKE_C_FLAGS_DEBUG "-O0 -g" CACHE STRING "c Debug flags")
set(CMAKE_C_FLAGS_RELEASE "-O2" CACHE STRING "c Release flags")
set(CMAKE_CXX_FLAGS_DEBUG "-O0 -g $ENV{LOCAL_CXXFLAGS}" CACHE STRING "c++ Debug flags")
set(CMAKE_CXX_FLAGS_RELEASE "-O2 $ENV{LOCAL_CXXFLAGS}" CACHE STRING "c++ Release flags")
