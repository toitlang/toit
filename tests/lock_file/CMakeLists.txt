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

file(GLOB PACKAGE_LOCK_TESTS "*_test")

foreach(dir ${PACKAGE_LOCK_TESTS})
  file(RELATIVE_PATH test_prefix ${TOIT_SDK_SOURCE_DIR} ${dir})
  set(test1 "${test_prefix}/test.toit")
  add_test(
    NAME ${test1}
    COMMAND $<TARGET_FILE:toitvm> ${test1}
    WORKING_DIRECTORY ${TOIT_SDK_SOURCE_DIR}
    )
  set_tests_properties(${test1} PROPERTIES TIMEOUT 40)

  set(test2 "${test_prefix}")
  add_test(
    NAME ${test2}
    COMMAND $<TARGET_FILE:toitvm> ${CMAKE_CURRENT_SOURCE_DIR}/absolute_pkg.toit $<TARGET_FILE:toitvm> ${test_prefix}
    WORKING_DIRECTORY ${TOIT_SDK_SOURCE_DIR}
    )
  set_tests_properties(${test2} PROPERTIES TIMEOUT 40)
endforeach()

include(fail.cmake)
foreach(test ${TOIT_FAILING_TESTS})
  set_tests_properties(${test} PROPERTIES WILL_FAIL TRUE)
endforeach()
