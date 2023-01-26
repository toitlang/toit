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

file(GLOB TOIT_TESTS RELATIVE ${TOIT_SDK_SOURCE_DIR} "*_test.toit" "regress/*_test.toit")
file(GLOB TOIT_SLOW_TESTS RELATIVE ${TOIT_SDK_SOURCE_DIR} "*_test_slow.toit" "regress/*_test_slow.toit")
file(GLOB TOIT_FORCE_TESTS RELATIVE ${TOIT_SDK_SOURCE_DIR} "*_test_force.toit" "regress/*_test_force.toit")
file(GLOB TOIT_NO_BOOT_TESTS RELATIVE ${TOIT_SDK_SOURCE_DIR} "*_test_no_boot.toit" "regress/*_test_no_boot.toit")
file(GLOB TOIT_COMPILER_TESTS RELATIVE ${TOIT_SDK_SOURCE_DIR} "*_test_compiler.toit" "regress/*_test_compiler.toit")

set(ALL_TESTS ${TOIT_TESTS} ${TOIT_SLOW_TESTS} ${TOIT_FORCE_TESTS} ${TOIT_NO_BOOT_TESTS} ${TOIT_COMPILER_TESTS})

toit_project(tests "${CMAKE_CURRENT_LIST_DIR}")

include(ProcessorCount)
ProcessorCount(NUM_CPU)

IF(APPLE)
  set(DEFAULT_TIMEOUT 80)
  set(SLOW_TIMEOUT 800)
else()
  set(DEFAULT_TIMEOUT 40)
  set(SLOW_TIMEOUT 400)
endif()

# The SHARD_START end SHARD_STRIDE environment variables must be set when
# generating the cmake files.
# I couldn't figure out how to use them while running the tests.
set(TEST_SHARD_START "$ENV{SHARD_START}")
set(TEST_SHARD_STRIDE "$ENV{SHARD_STRIDE}")

add_custom_target(
  check
  COMMAND ${CMAKE_CTEST_COMMAND} -j${NUM_CPU} -T test --output-on-failure -I ${TEST_SHARD_START},,${TEST_SHARD_STRIDE}
  USES_TERMINAL
  DEPENDS build_tools
  )

add_custom_target(
  check_slow
  COMMAND ${CMAKE_CTEST_COMMAND} -j${NUM_CPU} -T test -C slow --output-on-failure  -I ${TEST_SHARD_START},,${TEST_SHARD_STRIDE}
  USES_TERMINAL
  DEPENDS build_tools
  )

include(fail.cmake)

foreach(file ${ALL_TESTS})
  if("${file}" IN_LIST TOIT_SKIP_TESTS)
    continue()
  endif()

  set(TOIT_ARGS) # Arguments to toit.run.
  set(TEST_ARGS) # Arguments to the test.

  if("${file}" IN_LIST TOIT_FORCE_TESTS)
    set(TOIT_ARGS "--force")
  elseif("${file}" IN_LIST TOIT_NO_BOOT_TESTS)
    set(TOIT_ARGS "-b" "none")
  elseif("${file}" IN_LIST TOIT_COMPILER_TESTS)
    set(TEST_ARGS "$<TARGET_FILE:toit.run>")
  else()
    # We add 3 arguments to all test-calls.
    # They are only used for tests that deal with arguments.
    set(TEST_ARGS "foo" "bar" "gee")
  endif()
  add_test(
    NAME ${file}
    COMMAND $<TARGET_FILE:toit.run> ${TOIT_ARGS} ${file} ${TEST_ARGS}
    WORKING_DIRECTORY ${TOIT_SDK_SOURCE_DIR}
    )

  set_tests_properties(${file} PROPERTIES ENVIRONMENT "TOIT_TEST_ENV_ENTRY=TOIT_TEST_ENV_VALUE")

  if("${file}" IN_LIST TOIT_SLOW_TESTS)
    set_tests_properties(${file} PROPERTIES TIMEOUT ${SLOW_TIMEOUT})
  else()
    set_tests_properties(${file} PROPERTIES TIMEOUT ${DEFAULT_TIMEOUT})
  endif()
  if("${file}" IN_LIST TOIT_FAILING_TESTS)
    set_tests_properties(${file} PROPERTIES WILL_FAIL TRUE)
  endif()
endforeach()

set(PREEMPT_ALOT_TEST "tests/json_test.toit")
add_test(
  NAME "${PREEMPT_ALOT_TEST}-PREEMPT_ALOT"
  COMMAND $<TARGET_FILE:toit.run> -Xpreemptalot ${PREEMPT_ALOT_TEST}
  WORKING_DIRECTORY ${TOIT_SDK_SOURCE_DIR}
  )

add_subdirectory(lsp)
add_subdirectory(minus_s)
add_subdirectory(negative)
add_subdirectory(type_propagation)
add_subdirectory(optimizations)
add_subdirectory(ctest)
add_subdirectory(toitp)
add_subdirectory(image)
add_subdirectory(profiler)
add_subdirectory(health)
add_subdirectory(fuzzer)
add_subdirectory(cmake)
add_subdirectory(lock_file)
add_subdirectory(vessels)
