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

file(GLOB SINGLE_TESTS RELATIVE ${CMAKE_CURRENT_SOURCE_DIR} "*-test.toit")
file(GLOB MULTI_TESTS RELATIVE ${CMAKE_CURRENT_SOURCE_DIR} "*-board1.toit")

set(TESTER ${CMAKE_CURRENT_SOURCE_DIR}/../esp-tester/tester.toit)

add_custom_target(
  check_esp32
  COMMAND ${CMAKE_CTEST_COMMAND} -j1 -T test -C esp32 --output-on-failure
  USES_TERMINAL
  )

foreach(board board1 board2)
  if (board STREQUAL "board1")
    set(port "$ENV{ESP32_BOARD1_PORT}")
  else()
    set(port "$ENV{ESP32_BOARD2_PORT}")
  endif()
  add_test(
    NAME "setup-${board}"
    COMMAND "${TOIT_EXE_HW}" "${TESTER}" setup
        --verbose
        --toit-exe "${TOIT_EXE_HW}"
        --port "${port}"
        --envelope "$ENV{ESP32_ENVELOPE}"
        --wifi-ssid "$ENV{ESP32_WIFI_SSID}"
        --wifi-password "$ENV{ESP32_WIFI_PASSWORD}"
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    CONFIGURATIONS esp32 hw
    )

  set_tests_properties("setup-${board}" PROPERTIES TIMEOUT 40)
  set_tests_properties("setup-${board}" PROPERTIES FIXTURES_SETUP "setup-boards")
endforeach()

foreach(file ${SINGLE_TESTS})
  get_filename_component(name ${file} NAME_WE)
  set(toit_file ${CMAKE_CURRENT_SOURCE_DIR}/${file})
  set(test_name ${name})

  add_test(
    NAME ${file}
    COMMAND ${TOIT_EXE_HW} "${TESTER}" run ${toit_file}
        --verbose
        --toit-exe "${TOIT_EXE_HW}"
        --port-board1 "$ENV{ESP32_BOARD1_PORT}"
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    CONFIGURATIONS esp32
    )

  set_tests_properties(${file} PROPERTIES TIMEOUT 120)
  set_tests_properties(${file} PROPERTIES FIXTURES_REQUIRED "setup-boards")
endforeach()

foreach(file ${MULTI_TESTS})
  get_filename_component(name ${file} NAME_WE)
  set(toit_file ${CMAKE_CURRENT_SOURCE_DIR}/${file})
  set(test_name ${name})

  string(REPLACE "board1" "board2" toit_file_board2 ${toit_file})

  add_test(
    NAME ${file}
    COMMAND ${TOIT_EXE_HW} "${TESTER}" run ${toit_file} ${toit_file_board2}
        --verbose
        --toit-exe "${TOIT_EXE_HW}"
        --port-board1 "$ENV{ESP32_BOARD1_PORT}"
        --port-board2 "$ENV{ESP32_BOARD2_PORT}"
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    CONFIGURATIONS esp32 hw
    )

  set_tests_properties(${file} PROPERTIES TIMEOUT 120)
  set_tests_properties(${file} PROPERTIES FIXTURES_REQUIRED "setup-boards")
endforeach()
