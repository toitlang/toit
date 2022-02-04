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

set(HEALTH_TEST_PREFIX "health-")

# Adds a health-test.
# Adds the tests to test configuration 'health'.
function (add_health_test PATH)
  set(PARAMS RELATIVE_TO LIB_DIR GOLD_DIR CONFIGURATION UPDATE_TARGET)
  cmake_parse_arguments(
      MY_HEALTH    # Prefix
      ""
      "${PARAMS}"  # One value parameters.
      ""
      ${ARGN})
  set(RELATIVE_TO "${MY_HEALTH_RELATIVE_TO}")
  set(LIB_DIR "${MY_HEALTH_LIB_DIR}")
  set(GOLD_DIR "${MY_HEALTH_GOLD_DIR}")
  set(CONFIGURATION "${MY_HEALTH_CONFIGURATION}")
  set(UPDATE_TARGET "${MY_HEALTH_UPDATE_TARGET}")

  get_filename_component(NAME "${PATH}" NAME_WE)
  file(RELATIVE_PATH TEST_NAME "${CMAKE_SOURCE_DIR}" "${PATH}")
  set(TEST_NAME "${HEALTH_TEST_PREFIX}${TEST_NAME}")

  file(RELATIVE_PATH RELATIVE "${RELATIVE_TO}" "${PATH}")
  string(REPLACE " " "__" ESCAPED "${RELATIVE}")
  string(REPLACE "/" "__" ESCAPED "${ESCAPED}")
  set(GOLD "${GOLD_DIR}/${ESCAPED}.gold")

  add_test(
    NAME "${TEST_NAME}"
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
    CONFIGURATIONS "${CONFIGURATION}"
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
        -P "${TOOLS_DIR}/health_run.cmake"
    WORKING_DIRECTORY "${RELATIVE_TO}"
  )
  add_dependencies("${UPDATE_TARGET}" "${generate_gold}")
endfunction()
