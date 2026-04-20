# Copyright (C) 2026 Toit contributors.
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

file(GLOB FORMATTER_TESTS "*-test.toit")

include(fail.cmake OPTIONAL)

foreach(file ${FORMATTER_TESTS})
  file(RELATIVE_PATH test_name ${TOIT_SDK_SOURCE_DIR} ${file})
  if (NOT "${test_name}" IN_LIST TOIT_SKIP_TESTS)
    set(TEST_EXPECTATION_NAME "${test_name}")
    if("${test_name}" IN_LIST TOIT_FAILING_TESTS)
      set(TEST_EXPECTATION_NAME "${test_name}-expected-to-fail")
    endif()

    add_test(
      NAME ${TEST_EXPECTATION_NAME}
      COMMAND $<TARGET_FILE:toit.run> ${file} $<TARGET_FILE:toit> ${TOIT_SDK_SOURCE_DIR}
      )
    # The formatter tests (especially round-trip) invoke `toit format` many
    # times over lib/, which can exceed DEFAULT_TIMEOUT.
    set_tests_properties(${TEST_EXPECTATION_NAME} PROPERTIES TIMEOUT ${SLOW_TIMEOUT})
    if ("${test_name}" IN_LIST TOIT_FAILING_TESTS)
      set_tests_properties(${TEST_EXPECTATION_NAME} PROPERTIES WILL_FAIL TRUE)
    endif()
  endif()
endforeach()
