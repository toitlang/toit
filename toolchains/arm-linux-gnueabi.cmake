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

set(ARM_TARGET "arm-linux-gnueabi" CACHE STRING "The ARM target for the toolchain")

set(ARM_CPU_FLAGS "-marm -march=armv5te -mtune=arm926ej-s -msoft-float -mfloat-abi=soft"
                  CACHE STRING "The ARM CPU flags for the toolchain")

set(CMAKE_EXE_LINKER_FLAGS_INIT "${CMAKE_EXE_LINKER_FLAGS_INIT} -no-pie -latomic"
                                CACHE STRING "The linker flags for the toolchain")

include("${CMAKE_CURRENT_LIST_DIR}/arm32.cmake")
