# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

# Compiles some of the tests to native code and runs them. Native code relies
# on tail calls for everything, so we need a compiler that guarantees them.
find_program(TOIT_NATIVE_CXX clang++)
if (NOT TOIT_NATIVE_SUPPORTED OR NOT TARGET toit_native_main)
  return()
endif()
# These configurations are for testing other things.
if (DEFINED ENV{TOIT_CHECK_PROPAGATED_TYPES} OR DEFINED ENV{TOIT_OPTIMIZATION_OVERRIDE} OR
    DEFINED ENV{TOIT_ASSERT_OVERRIDE})
  return()
endif()
if (NOT TOIT_NATIVE_CXX)
  # Don't let CI pass because it silently skipped everything.
  if (DEFINED ENV{CI})
    message(FATAL_ERROR "Testing native code needs clang++")
  endif()
  return()
endif()

set(NATIVE_TESTS
  float-temporary-test
  hash-do-mutation-test
  typed-arithmetic-test
  catch-test
  exception-test
  lambda-test
  list-test
  map-test
  monitor-test
  non-local-branch-regression-test
  non-local-branch-types-test
  string-test
  task-test
  thread-test
  try-finally-test
)

# These are also compiled without debug information.
set(NATIVE_STRIPPED_TESTS
  exception-test
  task-test
)

set(NATIVE_DIR "${CMAKE_BINARY_DIR}/native_test")

function(add_native_test name source)
  set(executable "${NATIVE_DIR}/${name}")
  # The tests only use the SDK, so they don't need the packages of the other tests.
  add_custom_command(
    OUTPUT "${executable}"
    COMMAND "${CMAKE_COMMAND}" -E make_directory "${NATIVE_DIR}"
    COMMAND "${CMAKE_COMMAND}" -E env "TOIT_CXX=${TOIT_NATIVE_CXX}"
        $<TARGET_FILE:toit.compile> --project-root "${CMAKE_CURRENT_SOURCE_DIR}" ${ARGN} -o "${executable}" "${source}"
    DEPENDS toit.compile build_native_sdk "${source}"
  )
  add_custom_target("native-${name}" DEPENDS "${executable}")
  add_dependencies(build_test_assets "native-${name}")
  add_test(
    NAME "tests/native/${name}"
    COMMAND "${executable}" foo bar gee
    WORKING_DIRECTORY "${TOIT_SDK_SOURCE_DIR}"
    CONFIGURATIONS slow
  )
endfunction()

foreach(test ${NATIVE_TESTS})
  add_native_test("${test}" "${CMAKE_CURRENT_SOURCE_DIR}/../${test}.toit" --native)
endforeach()

# Tests that only make sense for native code.
add_native_test("unsupported-launch-test" "${CMAKE_CURRENT_SOURCE_DIR}/unsupported-launch-test.toit" --native)

foreach(test ${NATIVE_STRIPPED_TESTS})
  add_native_test("${test}-stripped" "${CMAKE_CURRENT_SOURCE_DIR}/../${test}.toit" --native --strip)
endforeach()

# The benchmarks cover a lot of ground, and they are quick to run once. This
# isn't about how fast they are: they must print what they do with bytecodes.
set(NATIVE_BENCHMARKS_DIR "${TOIT_SDK_SOURCE_DIR}/benchmarks")
file(GLOB NATIVE_BENCHMARKS CONFIGURE_DEPENDS "${NATIVE_BENCHMARKS_DIR}/*.toit")
foreach(source ${NATIVE_BENCHMARKS})
  get_filename_component(name "${source}" NAME_WE)
  set(executable "${NATIVE_DIR}/benchmark-${name}")
  add_custom_command(
    OUTPUT "${executable}"
    COMMAND "${CMAKE_COMMAND}" -E make_directory "${NATIVE_DIR}"
    COMMAND "${CMAKE_COMMAND}" -E env "TOIT_CXX=${TOIT_NATIVE_CXX}"
        $<TARGET_FILE:toit.compile> --native -o "${executable}" "${source}"
    DEPENDS toit.compile build_native_sdk "${source}"
  )
  add_custom_target("native-benchmark-${name}" DEPENDS "${executable}")
  add_dependencies(build_test_assets "native-benchmark-${name}")
  add_test(
    NAME "tests/native/benchmark-${name}"
    COMMAND "${CMAKE_COMMAND}"
        "-DEXECUTABLE=${executable}"
        "-DGOLD=${NATIVE_BENCHMARKS_DIR}/gold/${name}.gold"
        -P "${CMAKE_CURRENT_SOURCE_DIR}/benchmark-test.cmake"
    CONFIGURATIONS slow
  )
endforeach()

add_test(
  NAME "tests/native/source-test"
  COMMAND "${CMAKE_COMMAND}"
      "-DTOIT_COMPILE=$<TARGET_FILE:toit.compile>"
      "-DCXX=${TOIT_NATIVE_CXX}"
      "-DSOURCE=${CMAKE_CURRENT_SOURCE_DIR}/source-input.toit"
      "-DNATIVE_SDK=${CMAKE_BINARY_DIR}/sdk/lib/toit/native"
      "-DWORK_DIR=${NATIVE_DIR}"
      -P "${CMAKE_CURRENT_SOURCE_DIR}/source-test.cmake"
  CONFIGURATIONS slow
)
