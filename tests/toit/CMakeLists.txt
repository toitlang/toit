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

file(GLOB TOIT_BIN_TESTS "*-test.toit")
file(GLOB ASSERT_TESTS "assert*-test.toit")

include(fail.cmake OPTIONAL)

set(TEST_SDK_DIR "${CMAKE_BINARY_DIR}/sdk")
set(TOIT_BIN_SOURCE "${TOIT_SDK_SOURCE_DIR}/tools/toit.toit")

set(ASSERT_IS_OVERRIDDEN FALSE)
if (DEFINED ENV{TOIT_ASSERT_OVERRIDE})
  set(ASSERT_IS_OVERRIDDEN TRUE)
endif()

foreach(file ${TOIT_BIN_TESTS})
  get_filename_component(base ${file} NAME_WE)

  if (ASSERT_IS_OVERRIDDEN AND "${file}" IN_LIST ASSERT_TESTS)
    message("Skipping ${file} as asserts are overridden")
    continue()
  endif()

  file(RELATIVE_PATH toit_bin_test_name ${TOIT_SDK_SOURCE_DIR} ${file})
  if (NOT "${toit_bin_test_name}" IN_LIST TOIT_SKIP_TESTS)
    set(TEST_EXPECTATION_NAME "${toit_bin_test_name}")
    if("${toit_bin_test_name}" IN_LIST TOIT_FAILING_TESTS)
      set(TEST_EXPECTATION_NAME "${toit_bin_test_name}-expected-to-fail")
    endif()

    add_test(
      NAME ${TEST_EXPECTATION_NAME}
      COMMAND $<TARGET_FILE:toit.run> ${file} $<TARGET_FILE:toit.run> ${TOIT_BIN_SOURCE} ${TEST_SDK_DIR}
      )
    set_tests_properties(${TEST_EXPECTATION_NAME} PROPERTIES TIMEOUT 120)
    if ("${toit_bin_test_name}" IN_LIST TOIT_FAILING_TESTS)
      set_tests_properties(${TEST_EXPECTATION_NAME} PROPERTIES WILL_FAIL TRUE)
    endif()
  endif()
endforeach()
