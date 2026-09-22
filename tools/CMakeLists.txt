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

include(toit.cmake)

toit_project(lsp "${CMAKE_CURRENT_LIST_DIR}/lsp/server")
toit_project(tools "${CMAKE_CURRENT_LIST_DIR}")

option(TOIT_BUILD_BLE_TEST_TOOLS "Build optional Linux BLE hardware supervision tools" OFF)
if (TOIT_BUILD_BLE_TEST_TOOLS AND CMAKE_SYSTEM_NAME STREQUAL "Linux")
  add_executable(ble-hci-supervisor ble-hci-supervisor.cc)
  target_compile_features(ble-hci-supervisor PRIVATE cxx_std_17)
  if (BUILD_TESTING)
    add_test(NAME tools/ble-hci-supervisor
      COMMAND bash "${CMAKE_SOURCE_DIR}/tests/ble-hardware/supervisor-test.sh"
        $<TARGET_FILE:ble-hci-supervisor> "${CMAKE_CURRENT_BINARY_DIR}/ble-supervisor-test")
    set_tests_properties(tools/ble-hci-supervisor PROPERTIES TIMEOUT 60)
  endif()
endif()
