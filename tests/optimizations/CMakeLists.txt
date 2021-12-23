file(GLOB TOIT_OPTIMIZATION_TESTS RELATIVE ${TOIT_SDK_SOURCE_DIR} "*_test.toit")

foreach(file ${TOIT_OPTIMIZATION_TESTS})
  add_test(
    NAME ${file}
    COMMAND $<TARGET_FILE:toitvm> ${TOIT_SDK_SOURCE_DIR}/${file} $<TARGET_FILE:toitvm> ${TOIT_SDK_SOURCE_DIR}/tools/lsp/server/server.toit
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    )
  set_tests_properties(${file} PROPERTIES TIMEOUT 40)
endforeach()

include(fail.cmake)
foreach(test ${TOIT_FAILING_TESTS})
  set_tests_properties(${test} PROPERTIES WILL_FAIL TRUE)
endforeach()
