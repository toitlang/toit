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

set(ARM_TARGET "arm-linux-gnueabihf")

set(ARM_CPU_FLAGS "-mcpu=cortex-a53 -mfloat-abi=hard -mfpu=neon-fp-armv8 -mneon-for-64bits")

# The Raspberry Pi doesn't seem to use position independent executables.
set(CMAKE_C_LINK_FLAGS "${CMAKE_CXX_LINK_FLAGS} -no-pie")
set(CMAKE_CXX_LINK_FLAGS "${CMAKE_CXX_LINK_FLAGS} -no-pie")

include("${CMAKE_CURRENT_LIST_DIR}/arm64.cmake")
