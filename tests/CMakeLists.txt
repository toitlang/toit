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

file(GLOB TOIT_TESTS RELATIVE ${TOIT_SDK_SOURCE_DIR} "*-test.toit" "regress/*-test.toit")
file(GLOB TOIT_SLOW_TESTS RELATIVE ${TOIT_SDK_SOURCE_DIR} "*-test-slow.toit" "regress/*-test-slow.toit")
file(GLOB TOIT_FORCE_TESTS RELATIVE ${TOIT_SDK_SOURCE_DIR} "*-test-force.toit" "regress/*-test-force.toit")
file(GLOB TOIT_NO_BOOT_TESTS RELATIVE ${TOIT_SDK_SOURCE_DIR} "*-test-no-boot.toit" "regress/*-test-no-boot.toit")
file(GLOB TOIT_COMPILER_TESTS RELATIVE ${TOIT_SDK_SOURCE_DIR} "*-test-compiler.toit" "regress/*-test-compiler.toit")

set(ALL_TESTS ${TOIT_TESTS} ${TOIT_SLOW_TESTS} ${TOIT_FORCE_TESTS} ${TOIT_NO_BOOT_TESTS} ${TOIT_COMPILER_TESTS})

toit_project(tests "${CMAKE_CURRENT_LIST_DIR}")
toit_project(esp32_tests "${CMAKE_CURRENT_LIST_DIR}/esp32")

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
  COMMAND ${CMAKE_CTEST_COMMAND} -j${NUM_CPU} --label-exclude "flaky" -T test --output-on-failure -I ${TEST_SHARD_START},,${TEST_SHARD_STRIDE}
  USES_TERMINAL
  DEPENDS build_tools
  )

add_custom_target(
  check_slow
  COMMAND ${CMAKE_CTEST_COMMAND} -j${NUM_CPU} --label-exclude "flaky" -T test -C slow --output-on-failure  -I ${TEST_SHARD_START},,${TEST_SHARD_STRIDE}
  USES_TERMINAL
  DEPENDS build_tools
  )

add_custom_target(
  check_flaky
  COMMAND ${CMAKE_CTEST_COMMAND} -j${NUM_CPU} --label-regex "flaky" -T test -C slow --output-on-failure  -I ${TEST_SHARD_START},,${TEST_SHARD_STRIDE}
  USES_TERMINAL
  DEPENDS build_tools
  )

add_custom_target(build_test_assets)
# Make sure the assets are built before we run the tests.
add_dependencies(check build_test_assets)
add_dependencies(check_slow build_test_assets)


# Create 15 flaky dummy tests, so that the strides mechanism works.
foreach(i RANGE 15)
  add_test(
    NAME "flaky_dummy_${i}"
    COMMAND ${CMAKE_COMMAND} -E echo "Flaky dummy test ${i}"
    )
  set_tests_properties("flaky_dummy_${i}" PROPERTIES LABELS "flaky")
endforeach()

include(fail.cmake OPTIONAL)

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
    set(TEST_ARGS "$<TARGET_FILE:toit.run>" "$<TARGET_FILE:toit.compile>")
  else()
    # We add 3 arguments to all test-calls.
    # They are only used for tests that deal with arguments.
    set(TEST_ARGS "foo" "bar" "gee")
  endif()

  set(TEST_CONFIGURATIONS)
  if ("${file}" IN_LIST TOIT_SLOW_TESTS)
    set(TEST_CONFIGURATIONS "slow")
  endif()

  set(TEST_EXPECTATION_NAME ${file})
  if("${file}" IN_LIST TOIT_FAILING_TESTS)
    set(TEST_EXPECTATION_NAME "${file}-expected-to-fail")
  endif()

  add_test(
    NAME ${TEST_EXPECTATION_NAME}
    COMMAND $<TARGET_FILE:toit.run> ${TOIT_ARGS} ${file} ${TEST_ARGS}
    WORKING_DIRECTORY ${TOIT_SDK_SOURCE_DIR}
    CONFIGURATIONS ${TEST_CONFIGURATIONS}
    )

  set_tests_properties(${TEST_EXPECTATION_NAME} PROPERTIES ENVIRONMENT "TOIT_TEST_ENV_ENTRY=TOIT_TEST_ENV_VALUE")

  if("${file}" IN_LIST TOIT_SLOW_TESTS)
    set_tests_properties(${TEST_EXPECTATION_NAME} PROPERTIES TIMEOUT ${SLOW_TIMEOUT})
  else()
    set_tests_properties(${TEST_EXPECTATION_NAME} PROPERTIES TIMEOUT ${DEFAULT_TIMEOUT})
  endif()
  if("${file}" IN_LIST TOIT_FAILING_TESTS)
    set_tests_properties(${TEST_EXPECTATION_NAME} PROPERTIES WILL_FAIL TRUE)
  endif()
  if("${file}" IN_LIST TOIT_FLAKY_TESTS)
    set_tests_properties(${TEST_EXPECTATION_NAME} PROPERTIES LABELS "flaky")
  endif()
endforeach()

set(PREEMPT_A_LOT_TEST "tests/json-test.toit")
add_test(
  NAME "${PREEMPT_A_LOT_TEST}-PREEMPT_A_LOT"
  COMMAND $<TARGET_FILE:toit.run> -Xpreempt_a_lot ${PREEMPT_A_LOT_TEST}
  WORKING_DIRECTORY ${TOIT_SDK_SOURCE_DIR}
  )

add_subdirectory(lsp)
add_subdirectory(minus_s)
add_subdirectory(negative)
add_subdirectory(type_propagation)
add_subdirectory(optimizations)
add_subdirectory(ctest)
add_subdirectory(toit)
add_subdirectory(toitp)
add_subdirectory(image)
add_subdirectory(profiler)
add_subdirectory(health)
add_subdirectory(fuzzer)
add_subdirectory(cmake)
add_subdirectory(lock_file)
add_subdirectory(vessels)
add_subdirectory(valgrind)
add_subdirectory(strip)
add_subdirectory(pkg)
add_subdirectory(envelope)
add_subdirectory(toitdoc)
add_subdirectory(dependencies)
