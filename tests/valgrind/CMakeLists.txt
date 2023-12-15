# Copyright (C) 2023 Toitware ApS.
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

# Valgrind only works on Linux.
# Return if we are on any other platform.
if(NOT CMAKE_SYSTEM_NAME STREQUAL "Linux")
  return()
endif()

file(GLOB VALGRIND_TESTS RELATIVE "${CMAKE_CURRENT_SOURCE_DIR}" "*-test.toit")

set(VALGRIND_TEST_DIR ${CMAKE_BINARY_DIR}/valgrind_test)

include("${TOIT_SDK_SOURCE_DIR}/tools/toit.cmake")

set(TOITP_SOURCE "${TOIT_SDK_SOURCE_DIR}/tools/toitp.toit")
set(TOITP_EXE "${CMAKE_CURRENT_BINARY_DIR}/toitp${CMAKE_EXECUTABLE_SUFFIX}")
set(TOITP_DEP "${CMAKE_CURRENT_BINARY_DIR}/toitp.dep")

set(CTEST_DIR ${CMAKE_BINARY_DIR}/ctest)

include(fail.cmake OPTIONAL)

foreach(file ${VALGRIND_TESTS})
  file(RELATIVE_PATH test_name ${PROJECT_SOURCE_DIR} "${CMAKE_CURRENT_SOURCE_DIR}/${file}")

  if("${test_name}" IN_LIST TOIT_SKIP_TESTS)
    continue()
  endif()

  set(input "${CMAKE_CURRENT_SOURCE_DIR}/${file}")
  set(snap ${VALGRIND_TEST_DIR}/${file}.snap)

  set(valgrind_xml_prefix ${VALGRIND_TEST_DIR}/${file}.valgrind)

  set(TEST_EXPECTATION_NAME "${test_name}")
  if("${test_name}" IN_LIST TOIT_FAILING_TESTS)
    set(TEST_EXPECTATION_NAME "${test_name}-expected-to-fail")
  endif()
  add_test(
    NAME ${TEST_EXPECTATION_NAME}
    COMMAND ${CMAKE_COMMAND}
        -DTOIT_RUN=$<TARGET_FILE:toit.run>
        -DTOIT_COMPILE=$<TARGET_FILE:toit.compile>
        "-DINPUT=${input}"
        "-DSNAPSHOT=${snap}"
        "-DVALGRIND_XML_PREFIX=${valgrind_xml_prefix}"
        -P "${CMAKE_CURRENT_SOURCE_DIR}/run.cmake"
    CONFIGURATIONS slow
  )
  set_tests_properties(${TEST_EXPECTATION_NAME} PROPERTIES TIMEOUT 400)

  if("${test_name}" IN_LIST TOIT_FAILING_TESTS)
    set_tests_properties(${TEST_EXPECTATION_NAME} PROPERTIES WILL_FAIL TRUE)
  endif()
endforeach()
