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

file(GLOB S2I_TESTS "*_test.toit")

set(S2I_TEST_DIR ${CMAKE_BINARY_DIR}/snapshot_to_image_test)

# Image creation only works on Linux.
if (${CMAKE_SYSTEM_NAME} MATCHES "Linux")
  foreach(file ${S2I_TESTS})
    get_filename_component(base ${file} NAME_WE)
    string(REGEX REPLACE "_test$" "" test_name ${base})
    set(input ${CMAKE_CURRENT_SOURCE_DIR}/${test_name}_input.toit)
    set(test ${CMAKE_CURRENT_SOURCE_DIR}/${test_name}_test.toit)

    set(snap ${S2I_TEST_DIR}/${test_name}_input.snap)
    set(dep ${S2I_TEST_DIR}/${test_name}_input.dep)

    ADD_TOIT_TARGET(
      ${input}
      ${snap}
      ${dep}
      "")

    set(build_snap tests-s2i-build_${test_name}_input)
    add_custom_target(${build_snap} DEPENDS ${snap})

    # Make sure the test input is built before we run the tests.
    add_dependencies(check ${build_snap})
    add_dependencies(check_slow ${build_snap})

    file(RELATIVE_PATH test_name ${TOIT_SDK_SOURCE_DIR} ${test})
    add_test(
      NAME ${test_name}
      COMMAND $<TARGET_FILE:toitvm> ${test} ${snap} $<TARGET_FILE:toitvm> ${TOIT_SDK_SOURCE_DIR}/tools/snapshot_to_image.toit
      )
    set_tests_properties(${test_name} PROPERTIES TIMEOUT 40)
  endforeach()
endif()
