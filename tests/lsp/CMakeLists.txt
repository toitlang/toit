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

file(GLOB TOIT_COMPLETION_TESTS RELATIVE ${TOIT_SDK_SOURCE_DIR} "*completion_test.toit" "*/*completion_test.toit" "*/*/*completion_test.toit" "*/*/*/*completion_test.toit")
file(GLOB TOIT_GOTO_DEFINITION_TESTS RELATIVE ${TOIT_SDK_SOURCE_DIR} "*definition_test.toit"  "*/*definition_test.toit" "*/*/*definition_test.toit" "*/*/*/*definition_test.toit")
file(GLOB TOIT_COMPILER_TESTS RELATIVE ${TOIT_SDK_SOURCE_DIR} "*compiler_test.toit")
file(GLOB TOIT_SLOW_COMPILER_TESTS RELATIVE ${TOIT_SDK_SOURCE_DIR} "*compiler_test_slow.toit")

set(MOCK_COMPILER_DIR ${CMAKE_BINARY_DIR}/lsp_test)

set(TOIT_LSP_BIN ${CMAKE_BINARY_DIR}/sdk/bin/toitlsp)
set(TOIT_LSP_SERVER_DIR ${TOIT_SDK_SOURCE_DIR}/tools/lsp/server)

# TODO(florian): set timeout to DEFAULT_TIMEOUT once we have removed the Toit version of the LSP server.
math(EXPR LSP_DOUBLE_TIMEOUT "${DEFAULT_TIMEOUT} * 2")

add_executable(
  mock_compiler
  mock_compiler.cc
  )

set_target_properties(mock_compiler PROPERTIES RUNTIME_OUTPUT_DIRECTORY ${MOCK_COMPILER_DIR})

target_link_libraries(
  mock_compiler
  ${TOIT_LINK_LIBS}
  )

add_dependencies(build_tools mock_compiler build_toitlsp)
add_dependencies(check mock_compiler)
add_dependencies(check_slow mock_compiler)

foreach(file ${TOIT_COMPLETION_TESTS})
  add_test(
    NAME ${file}
    COMMAND $<TARGET_FILE:toit.run> ${CMAKE_CURRENT_SOURCE_DIR}/completion_test_runner.toit ${TOIT_SDK_SOURCE_DIR}/${file} $<TARGET_FILE:toit.run> ${TOIT_LSP_SERVER_DIR}/server.toit $<TARGET_FILE:mock_compiler> ${TOIT_LSP_BIN}
    WORKING_DIRECTORY ${TOIT_SDK_SOURCE_DIR}
    )
  set_tests_properties(${file} PROPERTIES TIMEOUT ${LSP_DOUBLE_TIMEOUT})
  set_tests_properties(${file} PROPERTIES ENVIRONMENT "TOIT_DEBUG_COMPLETION=true")
endforeach()

foreach(file ${TOIT_GOTO_DEFINITION_TESTS})
  add_test(
    NAME ${file}
    COMMAND $<TARGET_FILE:toit.run> ${CMAKE_CURRENT_SOURCE_DIR}/goto_definition_test_runner.toit ${TOIT_SDK_SOURCE_DIR}/${file} $<TARGET_FILE:toit.run> ${TOIT_LSP_SERVER_DIR}/server.toit $<TARGET_FILE:mock_compiler> ${TOIT_LSP_BIN}
    WORKING_DIRECTORY ${TOIT_SDK_SOURCE_DIR}
    )
  set_tests_properties(${file} PROPERTIES TIMEOUT ${LSP_DOUBLE_TIMEOUT})
endforeach()

foreach(file ${TOIT_COMPILER_TESTS})
  add_test(
    NAME ${file}
    COMMAND $<TARGET_FILE:toit.run> ${TOIT_SDK_SOURCE_DIR}/${file} $<TARGET_FILE:toit.run> ${TOIT_LSP_SERVER_DIR}/server.toit $<TARGET_FILE:mock_compiler> ${TOIT_LSP_BIN}
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    )
  set_tests_properties(${file} PROPERTIES TIMEOUT ${DEFAULT_TIMEOUT})
endforeach()

foreach(file ${TOIT_SLOW_COMPILER_TESTS})
  add_test(
    NAME ${file}
    COMMAND $<TARGET_FILE:toit.run> ${TOIT_SDK_SOURCE_DIR}/${file} $<TARGET_FILE:toit.run> ${TOIT_LSP_SERVER_DIR}/server.toit $<TARGET_FILE:mock_compiler> ${TOIT_LSP_BIN}
    CONFIGURATIONS slow
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    )
  set_tests_properties(${file} PROPERTIES TIMEOUT ${SLOW_TIMEOUT})
endforeach()

include(fail.cmake)
foreach(test ${TOIT_FAILING_TESTS})
  set_tests_properties(${test} PROPERTIES WILL_FAIL TRUE)
endforeach()
