file(GLOB TESTS RELATIVE ${CMAKE_CURRENT_SOURCE_DIR} "*-test.toit" "*_test_slow.toit")

find_program(TOIT_EXEC toit)
if(NOT TOIT_EXEC)
  set(TOIT_EXEC "toit${CMAKE_EXECUTABLE_SUFFIX}")
endif()
set(TEST_TIMEOUT 40 CACHE STRING "The maximal amount of time each test is allowed to run")

message(STATUS "Toit executable: ${TOIT_EXEC}")

add_custom_target(
  "install-pkgs"
  COMMAND "${TOIT_EXEC}" pkg install
  WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
)

include(ProcessorCount)
ProcessorCount(NUM_CPU)

add_custom_target(
  "check"
  COMMAND "${CMAKE_CTEST_COMMAND}" -j${NUM_CPU} --output-on-failure -C Debug
  USES_TERMINAL
)

foreach(file ${TESTS})
  set(test_name "/tests/${file}")
  add_test(
    NAME "${test_name}"
    COMMAND "${TOIT_EXEC}" "tests/${file}"
    WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
  )
  set_tests_properties(${test_name} PROPERTIES TIMEOUT ${TEST_TIMEOUT})
endforeach()
