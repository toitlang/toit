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

file(GLOB PROFILER_TESTS "*-test.toit")

include(fail.cmake)

if (DEFINED ENV{TOIT_OPTIMIZATION_OVERRIDE})
  # Don't run profiler tests if the optimization level is overridden.
  set(PROFILER_TESTS)
endif()

foreach(profiler_test ${PROFILER_TESTS})
  get_filename_component(base ${profiler_test} NAME_WE)
  string(REGEX REPLACE "-test$" "" test_name ${base})
  set(profiler_input ${CMAKE_CURRENT_SOURCE_DIR}/${test_name}-input.toit)
  file(RELATIVE_PATH profiler_test_name ${TOIT_SDK_SOURCE_DIR} ${profiler_test})

  if("${profiler_test_name}" IN_LIST TOIT_SKIP_TESTS)
    continue()
  endif()

  set(TEST_EXPECTATION_NAME ${profiler_test_name})
  if("${profiler_test_name}" IN_LIST TOIT_FAILING_TESTS)
    set(TEST_EXPECTATION_NAME "${profiler_test_name}-expected-to-fail")
  endif()

  add_test(
    NAME ${TEST_EXPECTATION_NAME}
    COMMAND $<TARGET_FILE:toit.run> ${profiler_test} $<TARGET_FILE:toit.run> ${profiler_input}
    )
  set_tests_properties(${TEST_EXPECTATION_NAME} PROPERTIES TIMEOUT 40)

  if("${profiler_test_name}" IN_LIST TOIT_FAILING_TESTS)
    set_tests_properties(${TEST_EXPECTATION_NAME} PROPERTIES WILL_FAIL TRUE)
  endif()
endforeach()
