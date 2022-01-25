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

set(TOOLS_DIR "${CMAKE_CURRENT_LIST_DIR}")

# Adds a health-test.
# Adds the tests to test configuration 'health'.
function (add_health_test PATH RELATIVE_TO LIB_DIR GOLD_DIR)
  get_filename_component(NAME "${PATH}" NAME_WE)
  file(RELATIVE_PATH TEST_NAME "${CMAKE_SOURCE_DIR}" "${PATH}")

  file(RELATIVE_PATH RELATIVE "${RELATIVE_TO}" "${PATH}")
  string(REPLACE " " "__" ESCAPED "${RELATIVE}")
  string(REPLACE "/" "__" ESCAPED "${ESCAPED}")
  set(GOLD "${GOLD_DIR}/${ESCAPED}.gold")

  add_test(
    NAME ${TEST_NAME}
    COMMAND ${CMAKE_COMMAND}
        -DTOITC=$<TARGET_FILE:toit.compile>
        "-DTEST=${RELATIVE}"
        "-DGOLD=${GOLD}"
        "-DLIB_DIR=${LIB_DIR}"
        "-DTEST_ROOT=${RELATIVE_TO}"
        "-DTMP=${CMAKE_BINARY_DIR}/tmp"
        "-DCMAKE_SYSTEM_NAME=${CMAKE_SYSTEM_NAME}"
        -P "${TOOLS_DIR}/health_run.cmake"
    WORKING_DIRECTORY "${RELATIVE_TO}"
    CONFIGURATIONS health
    )

  set_tests_properties(${TEST_NAME} PROPERTIES TIMEOUT 40)

  set(generate_gold "build-health-${ESCAPED}.gold")
  add_custom_target("${generate_gold}")

  add_custom_command(
    TARGET ${generate_gold}
    COMMAND ${CMAKE_COMMAND}
        -DUPDATE_GOLD=true
        -DTOITC=$<TARGET_FILE:toit.compile>
        "-DTEST=${RELATIVE}"
        "-DGOLD=${GOLD}"
        "-DLIB_DIR=${LIB_DIR}"
        "-DTEST_ROOT=${RELATIVE_TO}"
        "-DTMP=${CMAKE_BINARY_DIR}/tmp"
        "-DCMAKE_SYSTEM_NAME=${CMAKE_SYSTEM_NAME}"
        -P "${TOOLS_DIR}/run.cmake"
    WORKING_DIRECTORY "${RELATIVE_TO}"
  )
  add_dependencies(update_health_gold ${generate_gold})
endfunction()
