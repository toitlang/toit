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

# Tests the vessel-generation for different snapshot sizes.
# 1. Builds Toit files that are then compiled with the Toit compiler.
# 2. Runs the generated executables.

# The sizes of byte-arrays inside the generated Toit files.
# By varying the size we ensure that the compiler picks the correct vessel (or at
# least one that is bigger than the snapshot).
set(SIZES 1 128 256 512 1024 1048576)
set(TEST_GENERATOR_SRC "${CMAKE_CURRENT_LIST_DIR}/test_generator.toit")

set(VESSEL_TEST_EXECUTABLES)
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
  list(APPEND VESSEL_TEST_EXECUTABLES ${GENERATED_TEST_EXE})

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
  list(APPEND VESSEL_TEST_EXECUTABLES ${GENERATED_TEST_STRIPPED_EXE})

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

add_custom_target(build_vessel_test_exes DEPENDS ${VESSEL_TEST_EXECUTABLES})
add_dependencies(check build_vessel_test_exes)
add_dependencies(check_slow build_vessel_test_exes)

