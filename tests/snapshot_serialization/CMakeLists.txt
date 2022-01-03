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

file(GLOB SNAPSHOT_SERIALIZATION_TESTS RELATIVE ${TOIT_SDK_SOURCE_DIR} "*_test.toit")

set(SNAPSHOT_SERIALIZATION_TEST_DIR ${CMAKE_BINARY_DIR}/snapshot_serialization_test)
set(SNAPSHOT_SERIALIZATION_INPUT ${CMAKE_CURRENT_SOURCE_DIR}/input.toit)

function(toit_to_snap toit snap_out dep_out)
  get_filename_component(base ${toit} NAME_WE)
  set(${snap_out} ${SNAPSHOT_SERIALIZATION_TEST_DIR}/${base}.snap PARENT_SCOPE)
  set(${dep_out} ${SNAPSHOT_SERIALIZATION_TEST_DIR}/${base}.dep PARENT_SCOPE)
endfunction()

toit_to_snap(
  ${SNAPSHOT_SERIALIZATION_INPUT}
  SNAPSHOT_SERIALIZATION_INPUT_SNAP
  SNAPSHOT_SERIALIZATION_INPUT_DEP
)

ADD_TOIT_TARGET(
  ${SNAPSHOT_SERIALIZATION_INPUT}
  ${SNAPSHOT_SERIALIZATION_INPUT_SNAP}
  ${SNAPSHOT_SERIALIZATION_INPUT_DEP}
  "")

set(build_snap tests_snapshot_serialization_build_input)
add_custom_target(${build_snap} DEPENDS ${SNAPSHOT_SERIALIZATION_INPUT_SNAP})
# Make sure the test input is built before we run the tests.
add_dependencies(check ${build_snap})
add_dependencies(check_slow ${build_snap})

foreach(file ${SNAPSHOT_SERIALIZATION_TESTS})
  add_test(
    NAME ${file}
    COMMAND $<TARGET_FILE:toit.run> ${file} $<TARGET_FILE:toit.run> ${CMAKE_CURRENT_SOURCE_DIR} ${SNAPSHOT_SERIALIZATION_INPUT_SNAP}
    WORKING_DIRECTORY ${TOIT_SDK_SOURCE_DIR}
    )
  set_tests_properties(${file} PROPERTIES TIMEOUT 40)
endforeach()
