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
  check_hw_esp32
  # Fail quickly and clearly when serial paths are absent or point at the
  # wrong chip family. The later commands are only run when this succeeds.
  COMMAND ${CMAKE_CTEST_COMMAND} -j2 -C hw --output-on-failure
      -R "^rig-preflight-"
  # Flash mini-jag and verify the board-to-board GPIO link before starting the
  # matrix.
  COMMAND ${CMAKE_CTEST_COMMAND} -j2 -C hw --output-on-failure
      -FA "^rig-preflight-"
      -R "^rig-health-board1\\.toit-(esp32|esp32s3)$"
  # Run only the ESP32 tests; Pi tests have an independent target.
  COMMAND ${CMAKE_CTEST_COMMAND} -j2 -T test -C hw --output-on-failure
      -FA "^(rig-preflight-|setup-boards-)"
      -R ".*-(esp32|esp32s3)$"
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

add_custom_target(check_hw DEPENDS check_pi check_hw_esp32)
