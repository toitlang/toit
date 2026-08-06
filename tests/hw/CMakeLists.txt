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

add_custom_target(
  check_hw
  # Fail quickly and clearly when serial paths are absent or point at the
  # wrong chip family. The later commands are only run when this succeeds.
  COMMAND ${CMAKE_CTEST_COMMAND} -j2 -C hw --output-on-failure
      -R "^rig-preflight-"
  # Flash mini-jag, verify the board-to-board GPIO link, and exercise one
  # representative S3 I2S clock/data transfer before starting the matrix.
  COMMAND ${CMAKE_CTEST_COMMAND} -j2 -C hw --output-on-failure
      -FA "^rig-preflight-"
      -R "^(rig-health-board1\\.toit-(esp32|esp32s3)|i2s-board1\\.toit-esp32s3-philips16)$"
  # The current Raspberry Pi can't run more than 2 tests in parallel.
  COMMAND ${CMAKE_CTEST_COMMAND} -j2 -T test -C hw --output-on-failure
      -FA "^(rig-preflight-|setup-boards-)"
      -E "^(rig-preflight-|rig-health-|setup-board)"
  VERBATIM
  USES_TERMINAL
  )

set(TOIT_EXE_HW "" CACHE FILEPATH "The executable used to run hardware tests")

if (NOT TOIT_EXE_HW)
  message(FATAL_ERROR "TOIT_EXE_HW not set")
endif()

enable_testing()

add_subdirectory(pi)
add_subdirectory(esp32)
