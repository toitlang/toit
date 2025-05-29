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

file(GLOB TOIT_COMPLETION_TESTS RELATIVE ${TOIT_SDK_SOURCE_DIR} "*completion-test.toit" "*/*completion-test.toit" "*/*/*completion-test.toit" "*/*/*/*completion-test.toit")
file(GLOB TOIT_GOTO_DEFINITION_TESTS RELATIVE ${TOIT_SDK_SOURCE_DIR} "*definition-test.toit"  "*/*definition-test.toit" "*/*/*definition-test.toit" "*/*/*/*definition-test.toit")
file(GLOB TOIT_COMPILER_TESTS RELATIVE ${TOIT_SDK_SOURCE_DIR} "*compiler-test.toit")
file(GLOB TOIT_SLOW_COMPILER_TESTS RELATIVE ${TOIT_SDK_SOURCE_DIR} "*compiler-test-slow.toit")

set(ALL_TESTS ${TOIT_COMPLETION_TESTS} ${TOIT_GOTO_DEFINITION_TESTS} ${TOIT_COMPILER_TESTS} ${TOIT_SLOW_COMPILER_TESTS})

set(MOCK_COMPILER_DIR ${CMAKE_BINARY_DIR}/lsp_test)

set(TOIT_LSP_SERVER_DIR ${TOIT_SDK_SOURCE_DIR}/tools/lsp/server)

# TODO(florian): set timeout to DEFAULT_TIMEOUT once we have removed the Toit version of the LSP server.
math(EXPR LSP_DOUBLE_TIMEOUT "${DEFAULT_TIMEOUT} * 4")

add_executable(
  mock_compiler
  mock_compiler.cc
  )

set_target_properties(mock_compiler PROPERTIES RUNTIME_OUTPUT_DIRECTORY ${MOCK_COMPILER_DIR})

target_link_libraries(
  mock_compiler
  ${TOIT_LINK_LIBS}
  )

add_dependencies(build_test_assets mock_compiler)

include(fail.cmake)

foreach(file ${ALL_TESTS})
  if("${file}" IN_LIST TOIT_SKIP_TESTS)
    continue()
  endif()

  set(TEST_EXPECTATION_NAME ${file})
  if("${file}" IN_LIST TOIT_FAILING_TESTS)
    set(TEST_EXPECTATION_NAME "${file}-expected-to-fail")
  endif()


  if ("${file}" IN_LIST TOIT_COMPLETION_TESTS)
    add_test(
      NAME ${TEST_EXPECTATION_NAME}
      COMMAND $<TARGET_FILE:toit.run> ${CMAKE_CURRENT_SOURCE_DIR}/completion-test-runner.toit ${TOIT_SDK_SOURCE_DIR}/${file} $<TARGET_FILE:toit> ${TOIT_LSP_SERVER_DIR}/server.toit $<TARGET_FILE:mock_compiler>
      WORKING_DIRECTORY ${TOIT_SDK_SOURCE_DIR}
      CONFIGURATIONS slow
      )
    set_tests_properties(${TEST_EXPECTATION_NAME} PROPERTIES TIMEOUT ${LSP_DOUBLE_TIMEOUT})
  elseif ("${file}" IN_LIST TOIT_GOTO_DEFINITION_TESTS)
    add_test(
      NAME ${TEST_EXPECTATION_NAME}
      COMMAND $<TARGET_FILE:toit.run> ${CMAKE_CURRENT_SOURCE_DIR}/goto-definition-test-runner.toit ${TOIT_SDK_SOURCE_DIR}/${file} $<TARGET_FILE:toit> ${TOIT_LSP_SERVER_DIR}/server.toit $<TARGET_FILE:mock_compiler>
      WORKING_DIRECTORY ${TOIT_SDK_SOURCE_DIR}
      CONFIGURATIONS slow
      )
    set_tests_properties(${TEST_EXPECTATION_NAME} PROPERTIES TIMEOUT ${LSP_DOUBLE_TIMEOUT})
  elseif ("${file}" IN_LIST TOIT_COMPILER_TESTS)
    add_test(
      NAME ${TEST_EXPECTATION_NAME}
      COMMAND $<TARGET_FILE:toit.run> ${TOIT_SDK_SOURCE_DIR}/${file} $<TARGET_FILE:toit> ${TOIT_LSP_SERVER_DIR}/server.toit $<TARGET_FILE:mock_compiler>
      WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
      CONFIGURATIONS slow
      )
    set_tests_properties(${TEST_EXPECTATION_NAME} PROPERTIES TIMEOUT ${LSP_DOUBLE_TIMEOUT})
  elseif ("${file}" IN_LIST TOIT_SLOW_COMPILER_TESTS)
    add_test(
      NAME ${TEST_EXPECTATION_NAME}
      COMMAND $<TARGET_FILE:toit.run> ${TOIT_SDK_SOURCE_DIR}/${file} $<TARGET_FILE:toit> ${TOIT_LSP_SERVER_DIR}/server.toit $<TARGET_FILE:mock_compiler>
      WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
      CONFIGURATIONS slow
      )
    set_tests_properties(${TEST_EXPECTATION_NAME} PROPERTIES TIMEOUT ${SLOW_TIMEOUT})
  else()
    message(FATAL_ERROR "Unknown test: ${file}")
  endif()

  if ("${file}" IN_LIST TOIT_SERIAL_TESTS)
    # Don't run this test in parallel with other tests.
    set_tests_properties(${TEST_EXPECTATION_NAME} PROPERTIES RUN_SERIAL TRUE)
  endif()

  if ("${file}" IN_LIST TOIT_FAILING_TESTS)
    set_tests_properties(${TEST_EXPECTATION_NAME} PROPERTIES WILL_FAIL TRUE)
  endif()
endforeach()
