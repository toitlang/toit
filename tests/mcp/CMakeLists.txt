# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

file(GLOB MCP_TESTS RELATIVE ${TOIT_SDK_SOURCE_DIR} "*-test.toit")

include(fail.cmake OPTIONAL)

foreach(file ${MCP_TESTS})
  if("${file}" IN_LIST TOIT_SKIP_TESTS)
    continue()
  endif()

  set(TEST_EXPECTATION_NAME ${file})
  if("${file}" IN_LIST TOIT_FAILING_TESTS)
    set(TEST_EXPECTATION_NAME "${file}-expected-to-fail")
  endif()

  add_test(
    NAME ${TEST_EXPECTATION_NAME}
    COMMAND $<TARGET_FILE:toit.run> "${TOIT_SDK_SOURCE_DIR}/${file}"
    WORKING_DIRECTORY ${TOIT_SDK_SOURCE_DIR}
    )

  if ("${file}" IN_LIST TOIT_FAILING_TESTS)
    set_tests_properties(${TEST_EXPECTATION_NAME} PROPERTIES WILL_FAIL TRUE)
  endif()
endforeach()
