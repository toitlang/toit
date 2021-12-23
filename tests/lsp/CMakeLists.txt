file(GLOB TOIT_COMPLETION_TESTS RELATIVE ${TOIT_SDK_SOURCE_DIR} "*completion_test.toit" "*/*completion_test.toit" "*/*/*completion_test.toit" "*/*/*/*completion_test.toit")
file(GLOB TOIT_GOTO_DEFINITION_TESTS RELATIVE ${TOIT_SDK_SOURCE_DIR} "*definition_test.toit"  "*/*definition_test.toit" "*/*/*definition_test.toit" "*/*/*/*definition_test.toit")
file(GLOB TOIT_COMPILER_TESTS RELATIVE ${TOIT_SDK_SOURCE_DIR} "*compiler_test.toit")
file(GLOB TOIT_SLOW_COMPILER_TESTS RELATIVE ${TOIT_SDK_SOURCE_DIR} "*compiler_test_slow.toit")

set(MOCK_COMPILER_DIR ${CMAKE_BINARY_DIR}/lsp_test)

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

add_dependencies(build_toitvm mock_compiler build_toitlsp)
add_dependencies(check mock_compiler)
add_dependencies(check_slow mock_compiler)

foreach(file ${TOIT_COMPLETION_TESTS})
  add_test(
    NAME ${file}
    COMMAND $<TARGET_FILE:toitvm> ${CMAKE_CURRENT_SOURCE_DIR}/completion_test_runner.toit ${TOIT_SDK_SOURCE_DIR}/${file} $<TARGET_FILE:toitvm> ${TOIT_SDK_SOURCE_DIR}/tools/lsp/server/server.toit $<TARGET_FILE:mock_compiler> ${CMAKE_SOURCE_DIR}/build/toitlsp
    WORKING_DIRECTORY ${TOIT_SDK_SOURCE_DIR}
    )
  set_tests_properties(${file} PROPERTIES TIMEOUT ${LSP_DOUBLE_TIMEOUT})
  set_tests_properties(${file} PROPERTIES ENVIRONMENT "TOIT_DEBUG_COMPLETION=true")
endforeach()

foreach(file ${TOIT_GOTO_DEFINITION_TESTS})
  add_test(
    NAME ${file}
    COMMAND $<TARGET_FILE:toitvm> ${CMAKE_CURRENT_SOURCE_DIR}/goto_definition_test_runner.toit ${TOIT_SDK_SOURCE_DIR}/${file} $<TARGET_FILE:toitvm> ${TOIT_SDK_SOURCE_DIR}/tools/lsp/server/server.toit $<TARGET_FILE:mock_compiler> ${CMAKE_SOURCE_DIR}/build/toitlsp
    WORKING_DIRECTORY ${TOIT_SDK_SOURCE_DIR}
    )
  set_tests_properties(${file} PROPERTIES TIMEOUT ${LSP_DOUBLE_TIMEOUT})
endforeach()

foreach(file ${TOIT_COMPILER_TESTS})
  add_test(
    NAME ${file}
    COMMAND $<TARGET_FILE:toitvm> ${TOIT_SDK_SOURCE_DIR}/${file} $<TARGET_FILE:toitvm> ${TOIT_SDK_SOURCE_DIR}/tools/lsp/server/server.toit $<TARGET_FILE:mock_compiler> ${CMAKE_SOURCE_DIR}/build/toitlsp
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    )
  set_tests_properties(${file} PROPERTIES TIMEOUT ${DEFAULT_TIMEOUT})
endforeach()

foreach(file ${TOIT_SLOW_COMPILER_TESTS})
  add_test(
    NAME ${file}
    COMMAND $<TARGET_FILE:toitvm> ${TOIT_SDK_SOURCE_DIR}/${file} $<TARGET_FILE:toitvm> ${TOIT_SDK_SOURCE_DIR}/tools/lsp/server/server.toit $<TARGET_FILE:mock_compiler> ${CMAKE_SOURCE_DIR}/build/toitlsp
    CONFIGURATIONS slow
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    )
  set_tests_properties(${file} PROPERTIES TIMEOUT ${SLOW_TIMEOUT})
endforeach()

include(fail.cmake)
foreach(test ${TOIT_FAILING_TESTS})
  set_tests_properties(${test} PROPERTIES WILL_FAIL TRUE)
endforeach()
