# Copyright (C) 2022 Toitware ApS.
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

set(TEST_EXECUTABLES)

set(VESSEL_TEST_ASSETS)

file(GLOB TOIT-TESTS RELATIVE ${TOIT_SDK_SOURCE_DIR} "*-test.toit")

# Test that the Toit compiler can compile a simple program from a snapshot.
set(SNAPSHOT_TEST_INPUT "${CMAKE_CURRENT_LIST_DIR}/snapshot-input.toit")
set(SNAPSHOT_TEST_SNAPSHOT "${CMAKE_CURRENT_BINARY_DIR}/snapshot-input.snapshot")
set(SNAPSHOT_TEST_DEP "${CMAKE_CURRENT_BINARY_DIR}/snapshot-input.dep")
set(SNAPSHOT_TEST_EXE "${CMAKE_CURRENT_BINARY_DIR}/snapshot-input.exe")

ADD_TOIT_SNAPSHOT(
  "${SNAPSHOT_TEST_INPUT}"
  "${SNAPSHOT_TEST_SNAPSHOT}"
  "${SNAPSHOT_TEST_DEP}"
  ""
)

add_custom_command(
  OUTPUT "${SNAPSHOT_TEST_EXE}"
  COMMAND $<TARGET_FILE:toit.compile> -o "${SNAPSHOT_TEST_EXE}" "${SNAPSHOT_TEST_SNAPSHOT}"
  DEPENDS $<TARGET_FILE:toit.compile> ${SNAPSHOT_TEST_SNAPSHOT}
)

list(APPEND VESSEL_TEST_ASSETS ${SNAPSHOT_TEST_EXE})

file(RELATIVE_PATH TEST_NAME ${TOIT_SDK_SOURCE_DIR} ${SNAPSHOT_TEST_EXE})

add_test(
  NAME "${TEST_NAME}"
  COMMAND "${SNAPSHOT_TEST_EXE}"
)

foreach(file ${TOIT-TESTS})
  set(TOIT_TEST ${file})
  set(ABSOLUTE_TEST_SOURCE ${TOIT_SDK_SOURCE_DIR}/${file})
  set(GENERATED_EXE ${CMAKE_CURRENT_BINARY_DIR}/${file}.exe)
  set(GENERATED_DEP ${CMAKE_CURRENT_BINARY_DIR}/${file}.dep)

  cmake_path(NATIVE_PATH GENERATED_EXE NORMALIZE NATIVE_EXE_PATH)

  ADD_TOIT_EXE(
    "${ABSOLUTE_TEST_SOURCE}"
    "${GENERATED_EXE}"
    "${GENERATED_DEP}"
    ""
  )

  list(APPEND VESSEL_TEST_ASSETS ${GENERATED_EXE})

  add_test(
    NAME "${TOIT_TEST}"
    COMMAND "${GENERATED_EXE}" "${GENERATED_EXE}" "${NATIVE_EXE_PATH}"
  )

  add_test(
    NAME "${TOIT_TEST}-relative"
    # We use `cmake` because ctest would otherwise make the test-path absolute.
    COMMAND ${CMAKE_COMMAND} -E env -- "${file}.exe" "${file}.exe" "${NATIVE_EXE_PATH}"
    WORKING_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}
  )
endforeach()

# Tests the vessel-generation for different snapshot sizes.
# 1. Builds Toit files that are then compiled with the Toit compiler.
# 2. Runs the generated executables.

# The sizes of byte-arrays inside the generated Toit files.
# By varying the size we ensure that the compiler picks the correct vessel (or at
# least one that is bigger than the snapshot).
set(SIZES 1 128 256 512 1024 1048576)
set(TEST_GENERATOR_SRC "${CMAKE_CURRENT_LIST_DIR}/test-generator.toit")

foreach(SIZE ${SIZES})
  set(GENERATED_TEST "${CMAKE_CURRENT_BINARY_DIR}/test-${SIZE}.toit")
  set(GENERATED_TEST_EXE "${CMAKE_CURRENT_BINARY_DIR}/test-${SIZE}.exe")
  set(GENERATED_TEST_STRIPPED_EXE "${CMAKE_CURRENT_BINARY_DIR}/test-stripped-${SIZE}.exe")
  set(GENERATED_TEST_DEP "${CMAKE_CURRENT_BINARY_DIR}/test-${SIZE}.dep")
  add_custom_command(
    OUTPUT "${GENERATED_TEST}"
    COMMAND $<TARGET_FILE:toit.run> "${TEST_GENERATOR_SRC}" "${GENERATED_TEST}" ${SIZE}
    DEPENDS $<TARGET_FILE:toit.run>
  )

  ADD_TOIT_EXE(
    "${GENERATED_TEST}"
    "${GENERATED_TEST_EXE}"
    "${GENERATED_TEST_DEP}"
    ""
  )
  list(APPEND VESSEL_TEST_ASSETS ${GENERATED_TEST_EXE})

  set(SIGN_ON_DARWIN)
  if ("${CMAKE_SYSTEM_NAME}" MATCHES "Darwin")
    set(SIGN_ON_DARWIN
      COMMAND "codesign" "-fs" "-" "${GENERATED_TEST_STRIPPED_EXE}"
    )
  endif()

  add_custom_command(
    OUTPUT "${GENERATED_TEST_STRIPPED_EXE}"
    COMMAND ${CMAKE_COMMAND} -E copy "${GENERATED_TEST_EXE}" "${GENERATED_TEST_STRIPPED_EXE}"
    COMMAND strip "${GENERATED_TEST_STRIPPED_EXE}"
    ${SIGN_ON_DARWIN}
    DEPENDS ${GENERATED_TEST_EXE}
  )
  list(APPEND VESSEL_TEST_ASSETS ${GENERATED_TEST_STRIPPED_EXE})

  file(RELATIVE_PATH TEST_NAME ${TOIT_SDK_SOURCE_DIR} ${GENERATED_TEST_EXE})
  add_test(
    NAME "${TEST_NAME}"
    COMMAND "${GENERATED_TEST_EXE}"
  )
  file(RELATIVE_PATH TEST_STRIPPED_NAME ${TOIT_SDK_SOURCE_DIR} ${GENERATED_TEST_STRIPPED_EXE})
  add_test(
    NAME "${TEST_STRIPPED_NAME}"
    COMMAND "${GENERATED_TEST_STRIPPED_EXE}"
  )
endforeach()

add_custom_target(build_vessel_test_assets DEPENDS ${VESSEL_TEST_ASSETS})
add_dependencies(build_test_assets build_vessel_test_assets)
