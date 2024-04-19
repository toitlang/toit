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

set(TOIT_BIN_TEST_DIR ${CMAKE_BINARY_DIR}/toit_bin_test)

include(fail.cmake)
include("${TOIT_SDK_SOURCE_DIR}/tools/toit.cmake")

set(TOIT_BIN_SOURCE "${TOIT_SDK_SOURCE_DIR}/tools/toit.toit")
set(TOIT_BIN_EXE "${CMAKE_CURRENT_BINARY_DIR}/toit${CMAKE_EXECUTABLE_SUFFIX}")
set(TOIT_BIN_DEP "${CMAKE_CURRENT_BINARY_DIR}/toit.dep")

# For simplicity build the toit executable for this test.
# We could try to use the one that is build in the bin directory but this approach is easier.
ADD_TOIT_EXE(
  ${TOIT_BIN_SOURCE}
  ${TOIT_BIN_EXE}
  ${TOIT_BIN_DEP}
  "")

add_custom_target(build_test_toit_bin_requirements DEPENDS ${TOIT_BIN_EXE})
add_dependencies(build_test_assets build_test_toit_bin_requirements)

foreach(file ${TOIT_BIN_TESTS})
  get_filename_component(base ${file} NAME_WE)

  file(RELATIVE_PATH toit_bin_test_name ${TOIT_SDK_SOURCE_DIR} ${file})
  if (NOT "${toit_bin_test_name}" IN_LIST TOIT_SKIP_TESTS)
    set(TEST_EXPECTATION_NAME "${toit_bin_test_name}")
    if("${toit_bin_test_name}" IN_LIST TOIT_FAILING_TESTS)
      set(TEST_EXPECTATION_NAME "${toit_bin_test_name}-expected-to-fail")
    endif()

    add_test(
      NAME ${TEST_EXPECTATION_NAME}
      COMMAND $<TARGET_FILE:toit.run> ${file} ${TOIT_BIN_EXE}
      DEPENDS ${TOIT_BIN_EXE}
      )
    set_tests_properties(${TEST_EXPECTATION_NAME} PROPERTIES TIMEOUT 40)
    if ("${toit_bin_test_name}" IN_LIST TOIT_FAILING_TESTS)
      set_tests_properties(${TEST_EXPECTATION_NAME} PROPERTIES WILL_FAIL TRUE)
    endif()
  endif()
endforeach()
