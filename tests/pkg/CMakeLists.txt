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

file(GLOB TOIT_PKG_TESTS RELATIVE ${TOIT_SDK_SOURCE_DIR} "*-test.toit")
file(GLOB TOIT_PKG_GOLD_TESTS RELATIVE ${TOIT_SDK_SOURCE_DIR} "*-gold-test.toit")

toit_project(pkg_tests "${CMAKE_CURRENT_LIST_DIR}")

add_custom_target(update_pkg_gold)

include(fail.cmake OPTIONAL)

foreach(file ${TOIT_PKG_TESTS})
  if("${file}" IN_LIST TOIT_SKIP_TESTS)
    continue()
  endif()

  set(TEST_EXPECTATION_NAME ${file})
  if("${file}" IN_LIST TOIT_FAILING_TESTS)
    set(TEST_EXPECTATION_NAME "${file}-expected-to-fail")
  endif()

  add_test(
    NAME ${TEST_EXPECTATION_NAME}
    COMMAND $<TARGET_FILE:toit> ${TOIT_SDK_SOURCE_DIR}/${file} $<TARGET_FILE:toit>
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    CONFIGURATIONS slow
    )
  set_tests_properties(${TEST_EXPECTATION_NAME} PROPERTIES TIMEOUT 40)

  if ("${file}" IN_LIST TOIT_PKG_GOLD_TESTS)
    set_tests_properties(${TEST_EXPECTATION_NAME} PROPERTIES TIMEOUT 100)
    string(REPLACE "/" "_" update_name "${file}")
    string(REPLACE "\\" "_" update_name "${update_name}")
    set(update_name "${update_name}-update-gold")
    add_custom_target(
      "${update_name}"
      COMMAND ${CMAKE_COMMAND} -E env "UPDATE_GOLD=1"
        $<TARGET_FILE:toit> ${TOIT_SDK_SOURCE_DIR}/${file} $<TARGET_FILE:toit>
      WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    )
    add_dependencies(update_pkg_gold "${update_name}")
  endif()

  if("${file}" IN_LIST TOIT_FAILING_TESTS)
    set_tests_properties(${TEST_EXPECTATION_NAME} PROPERTIES WILL_FAIL TRUE)
  endif()
endforeach()
