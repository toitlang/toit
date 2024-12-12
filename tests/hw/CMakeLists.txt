# Copyright (C) 2024 Toitware ApS.
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

cmake_minimum_required(VERSION 3.20.0)

project(hw NONE)  # No need for compilers.

set(HW_TOIT_EXE "" CACHE FILEPATH "The executable used to run hw tests")

if (NOT HW_TOIT_EXE)
  message(FATAL_ERROR "HW_TOIT_EXE not set")
endif()

enable_testing()

add_subdirectory(pi)
