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

file(GLOB TESTS RELATIVE "${TOIT_SDK_SOURCE_DIR}" "*-test.toit")

include(fail.cmake OPTIONAL)

foreach(file ${TESTS})
  if("${file}" IN_LIST TOIT_SKIP_TESTS)
    continue()
  endif()

  set(TEST_EXPECTATION_NAME ${file})
  if("${file}" IN_LIST TOIT_FAILING_TESTS)
    set(TEST_EXPECTATION_NAME "${file}-expected-to-fail")
  endif()

  add_test(
    NAME "${TEST_EXPECTATION_NAME}"
    COMMAND "$<TARGET_FILE:toit.run>" "${TOIT_SDK_SOURCE_DIR}/${file}"
        "$<TARGET_FILE:toit>"
        "${CMAKE_BINARY_DIR}/firmware.envelope"
        ${CMAKE_SIZEOF_VOID_P}
    CONFIGURATIONS slow
    )
  set_tests_properties(${TEST_EXPECTATION_NAME} PROPERTIES TIMEOUT 300)

  if("${file}" IN_LIST TOIT_FAILING_TESTS)
    set_tests_properties(${TEST_EXPECTATION_NAME} PROPERTIES WILL_FAIL TRUE)
  endif()
  if("${file}" IN_LIST TOIT_FLAKY_TESTS)
    set_tests_properties(${TEST_EXPECTATION_NAME} PROPERTIES LABELS "flaky")
  endif()
endforeach()
