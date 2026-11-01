# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

# Compiles some of the tests to native code and runs them. Native code relies
# on tail calls for everything, so we need a compiler that guarantees them.
if (NOT "${CMAKE_CXX_COMPILER_ID}" MATCHES "Clang" OR ${TOIT_IS_EMBEDDED})
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

set(NATIVE_DIR "${CMAKE_BINARY_DIR}/native_test")

foreach(test ${NATIVE_TESTS})
  set(source "${CMAKE_CURRENT_SOURCE_DIR}/../${test}.toit")
  set(code "${NATIVE_DIR}/${test}.cc")
  set(snapshot "${NATIVE_DIR}/${test}.snapshot")
  set(data "${NATIVE_DIR}/${test}-data.cc")
  set(target "native-${test}")

  add_custom_command(
    OUTPUT "${code}" "${snapshot}"
    COMMAND "${CMAKE_COMMAND}" -E make_directory "${NATIVE_DIR}"
    COMMAND $<TARGET_FILE:toit.compile> -O2 "-Xnative=${code}" -w "${snapshot}" "${source}"
    DEPENDS toit.compile "${source}"
  )
  add_custom_command(
    OUTPUT "${data}"
    COMMAND "${CMAKE_COMMAND}" "-DSNAPSHOT=${snapshot}" "-DOUTPUT=${data}"
        -P "${CMAKE_CURRENT_SOURCE_DIR}/embed-snapshot.cmake"
    DEPENDS "${snapshot}"
  )

  add_executable("${target}" EXCLUDE_FROM_ALL "${code}" "${data}")
  # The return addresses in native code must look like smis.
  target_compile_options("${target}" PRIVATE -falign-functions=4 -w)
  target_link_libraries("${target}" PRIVATE toit_native_main)
  set_target_properties("${target}" PROPERTIES RUNTIME_OUTPUT_DIRECTORY "${NATIVE_DIR}")
  add_dependencies(build_test_assets "${target}")

  add_test(
    NAME "tests/native/${test}"
    COMMAND "$<TARGET_FILE:${target}>" foo bar gee
    WORKING_DIRECTORY "${TOIT_SDK_SOURCE_DIR}"
    CONFIGURATIONS slow
  )
endforeach()
