# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

# Compiles some of the tests to native code and runs them. Native code relies
# on tail calls for everything, so we need a compiler that guarantees them.
find_program(TOIT_NATIVE_CXX clang++)
if (NOT TOIT_NATIVE_CXX OR NOT TARGET toit_native_main OR WIN32)
  return()
endif()

set(NATIVE_TESTS
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

# These are also compiled for size and without debug information.
set(NATIVE_SIZE_TESTS
  exception-test
  task-test
)

set(NATIVE_DIR "${CMAKE_BINARY_DIR}/native_test")

function(add_native_test name source)
  set(executable "${NATIVE_DIR}/${name}")
  add_custom_command(
    OUTPUT "${executable}"
    COMMAND "${CMAKE_COMMAND}" -E make_directory "${NATIVE_DIR}"
    COMMAND "${CMAKE_COMMAND}" -E env "TOIT_CXX=${TOIT_NATIVE_CXX}"
        $<TARGET_FILE:toit.compile> ${ARGN} -o "${executable}" "${source}"
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

foreach(test ${NATIVE_SIZE_TESTS})
  add_native_test("${test}-size" "${CMAKE_CURRENT_SOURCE_DIR}/../${test}.toit" --native-size --strip)
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
