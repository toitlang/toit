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

file(GLOB TOITP_TESTS "*-toitp-test.toit")

set(TOITP_TEST_DIR ${CMAKE_BINARY_DIR}/toitp_test)

include(fail.cmake)
include("${TOIT_SDK_SOURCE_DIR}/tools/toit.cmake")

set(TOITP_SOURCE "${TOIT_SDK_SOURCE_DIR}/tools/toitp.toit")
set(TOITP_EXE "${CMAKE_CURRENT_BINARY_DIR}/toitp${CMAKE_EXECUTABLE_SUFFIX}")
set(TOITP_DEP "${CMAKE_CURRENT_BINARY_DIR}/toitp.dep")

# For simplicity build the toitp executable for this test.
# We could try to use the one that is build in the tools directory but this approach is easier.
ADD_TOIT_EXE(
  ${TOITP_SOURCE}
  ${TOITP_EXE}
  ${TOITP_DEP}
  "")

add_executable(
  bytecode_lister
  bytecode_lister.cc
)

set_target_properties(
  bytecode_lister
  PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/toitp/bin"
)

set(BYTECODE_LIST ${TOITP_TEST_DIR}/bytecode.output)

add_custom_target(build_test_toitp_requirements DEPENDS ${TOITP_EXE} ${BYTECODE_LIST})
add_dependencies(build_test_assets build_test_toitp_requirements)

add_custom_command(
  OUTPUT ${BYTECODE_LIST}
  COMMAND $<TARGET_FILE:bytecode_lister> > ${BYTECODE_LIST}
  DEPENDS $<TARGET_FILE:bytecode_lister>
)

set(BYTECODE_MATCH_TEST ${CMAKE_CURRENT_SOURCE_DIR}/bytecode-match-test.toit)
file(RELATIVE_PATH BYTECODE_MATCH_TEST_NAME ${TOIT_SDK_SOURCE_DIR} ${BYTECODE_MATCH_TEST})
set(BYTECODE_MATCH_TEST_NAME tests-toitp-bytecode-match-test)
add_test(
  NAME ${BYTECODE_MATCH_TEST_NAME}
  COMMAND $<TARGET_FILE:toit.run> ${BYTECODE_MATCH_TEST} ${BYTECODE_LIST}
  DEPENDS ${BYTECODE_LIST}
  )

if (DEFINED ENV{TOIT_OPTIMIZATION_OVERRIDE})
  # Don't run toitp tests if the optimization level is overridden.
  set(TOITP_TESTS)
endif()

foreach(file ${TOITP_TESTS})
  get_filename_component(base ${file} NAME_WE)
  string(REGEX REPLACE "-toitp-test$" "" test_name ${base})
  set(input ${CMAKE_CURRENT_SOURCE_DIR}/${test_name}-input.toit)
  set(toitp_test ${CMAKE_CURRENT_SOURCE_DIR}/${test_name}-toitp-test.toit)
  set(snap_test ${CMAKE_CURRENT_SOURCE_DIR}/${test_name}-snap-test.toit)

  set(snap ${TOITP_TEST_DIR}/${test_name}-input.snap)
  set(dep ${TOITP_TEST_DIR}/${test_name}-input.dep)

  ADD_TOIT_SNAPSHOT(
    ${input}
    ${snap}
    ${dep}
    "")


  set(build_snap tests-toitp-build_${test_name}-input)
  add_custom_target(${build_snap} DEPENDS ${snap})

  add_dependencies(build_test_assets ${build_snap})

  file(RELATIVE_PATH toitp_test_name ${TOIT_SDK_SOURCE_DIR} ${toitp_test})
  if (NOT "${toitp_test_name}" IN_LIST TOIT_SKIP_TESTS)
    set(TEST_EXPECTATION_NAME "${toitp_test_name}")
    if("${toitp_test_name}" IN_LIST TOIT_FAILING_TESTS)
      set(TEST_EXPECTATION_NAME "${toitp_test_name}-expected-to-fail")
    endif()

    add_test(
      NAME ${TEST_EXPECTATION_NAME}
      COMMAND $<TARGET_FILE:toit.run> ${toitp_test} ${snap} $<TARGET_FILE:toit.run> ${TOITP_EXE}
      DEPENDS ${TOITP_EXE}
      )
    set_tests_properties(${TEST_EXPECTATION_NAME} PROPERTIES TIMEOUT 40)
    if ("${toitp_test_name}" IN_LIST TOIT_FAILING_TESTS)
      set_tests_properties(${TEST_EXPECTATION_NAME} PROPERTIES WILL_FAIL TRUE)
    endif()
  endif()

  file(RELATIVE_PATH snap_test_name ${TOIT_SDK_SOURCE_DIR} ${snap_test})
  if (NOT "${snap_test_name}" IN_LIST TOIT_SKIP_TESTS)
    set(TEST_EXPECTATION_NAME "${snap_test_name}")
    if("${snap_test_name}" IN_LIST TOIT_FAILING_TESTS)
      set(TEST_EXPECTATION_NAME "${snap_test_name}-expected-to-fail")
    endif()

    add_test(
      NAME ${TEST_EXPECTATION_NAME}
      COMMAND $<TARGET_FILE:toit.run> ${snap_test} ${snap}
      )
    set_tests_properties(${TEST_EXPECTATION_NAME} PROPERTIES TIMEOUT 40)
    if ("${snap_test_name}" IN_LIST TOIT_FAILING_TESTS)
      set_tests_properties(${TEST_EXPECTATION_NAME} PROPERTIES WILL_FAIL TRUE)
    endif()
  endif()
endforeach()
