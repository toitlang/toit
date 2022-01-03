# Copyright (C) 2021 Toitware ApS.
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

file(GLOB TOIT_FUZZER_LIB_TESTS RELATIVE ${TOIT_SDK_SOURCE_DIR} "../*_test.toit")

add_custom_target(
  check_fuzzer_lib
  COMMAND ${CMAKE_CTEST_COMMAND} -j${NUM_CPU} -T test -C fuzzer_lib --output-on-failure
  USES_TERMINAL
  DEPENDS toit.compile
  )

foreach(file ${TOIT_FUZZER_LIB_TESTS})
  set(TEST_NAME "tests/fuzzer/${file}")
  add_test(
    NAME ${TEST_NAME}
    COMMAND $<TARGET_FILE:toit.compile> --analyze -Xlib_path=${CMAKE_CURRENT_SOURCE_DIR} "${TOIT_SDK_SOURCE_DIR}/${file}"
    CONFIGURATIONS fuzzer_lib
    )
  set_tests_properties(${TEST_NAME} PROPERTIES TIMEOUT 10 WILL_FAIL true)
endforeach()
