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

include(${TOIT_SDK_SOURCE_DIR}/tools/toit.cmake)

# Tests the cmake rules.
# This includes the dependency resolution of ADD_TOIT_SNAPSHOT and ADD_TOIT_EXE.

# We use a directory with spaces to test that the dependency generation
# works in that case too.
set(CMAKE_TEST_INPUT_DIR "${CMAKE_BINARY_DIR}/cmake_test/dir with spaces")
set(CMAKE_TEST_INPUT "${CMAKE_TEST_INPUT_DIR}/input.toit")
# A file that is used to trigger a new output of the generator that uses the sources directly.
set(CMAKE_TEST_SOURCE_TRIGGER "${CMAKE_TEST_INPUT_DIR}/source.trigger")
set(CMAKE_TEST_SNAPSHOT "${CMAKE_BINARY_DIR}/cmake_test/cmake_test.snapshot")
set(CMAKE_TEST_EXE "${CMAKE_BINARY_DIR}/cmake_test/cmake_test.exe")

ADD_TOIT_SNAPSHOT(
  "${CMAKE_TEST_INPUT}"
  "${CMAKE_TEST_SNAPSHOT}"
  "${CMAKE_TEST_SNAPSHOT}.dep"
  "")

ADD_TOIT_EXE(
  "${CMAKE_TEST_INPUT}"
  "${CMAKE_TEST_EXE}"
  "${CMAKE_TEST_EXE}.dep"
  "")

add_custom_target(
  build_cmake_snapshot
  DEPENDS "${CMAKE_TEST_SNAPSHOT}" "${CMAKE_TEST_EXE}"
)

set(CMAKE_TEST_SNAPSHOT_OUTPUT "${CMAKE_BINARY_DIR}/cmake_test/snapshot.out")
set(CMAKE_TEST_EXE_OUTPUT "${CMAKE_BINARY_DIR}/cmake_test/exe.out")
set(CMAKE_TEST_SOURCE_OUTPUT   "${CMAKE_BINARY_DIR}/cmake_test/source.out")

# Used for the 'test_cmake' below.
add_custom_command(
  OUTPUT ${CMAKE_TEST_SNAPSHOT_OUTPUT}
  COMMAND $<TARGET_FILE:toit.run> ${CMAKE_TEST_SNAPSHOT} > ${CMAKE_TEST_SNAPSHOT_OUTPUT}
  DEPENDS ${CMAKE_TEST_SNAPSHOT}
)

# Used for the 'test_cmake' below.
add_custom_command(
  OUTPUT ${CMAKE_TEST_SOURCE_OUTPUT}
  COMMAND $<TARGET_FILE:toit.run> ${CMAKE_TEST_INPUT} > ${CMAKE_TEST_SOURCE_OUTPUT}
  DEPENDS ${CMAKE_TEST_SOURCE_TRIGGER}
)

# Used for the 'test_cmake' below.
add_custom_command(
  OUTPUT ${CMAKE_TEST_EXE_OUTPUT}
  COMMAND ${CMAKE_TEST_EXE} > ${CMAKE_TEST_EXE_OUTPUT}
  DEPENDS ${CMAKE_TEST_EXE}
)

# Used for the 'test_cmake' below.
add_custom_target(
  test_cmake_snapshot
  COMMAND diff ${CMAKE_TEST_SNAPSHOT_OUTPUT} ${CMAKE_TEST_SOURCE_OUTPUT}
  DEPENDS ${CMAKE_TEST_SNAPSHOT_OUTPUT} ${CMAKE_TEST_SOURCE_OUTPUT}
)

# Used for the 'test_cmake' below.
add_custom_target(
  test_cmake_exe
  COMMAND diff ${CMAKE_TEST_EXE_OUTPUT} ${CMAKE_TEST_SOURCE_OUTPUT}
  DEPENDS ${CMAKE_TEST_EXE_OUTPUT} ${CMAKE_TEST_SOURCE_OUTPUT}
)

# Target called from test.cmake.
add_custom_target(
  test_cmake
  DEPENDS test_cmake_snapshot test_cmake_exe
)

set(TEST_FILE "${CMAKE_CURRENT_SOURCE_DIR}/test.cmake")
file(RELATIVE_PATH TEST_NAME ${TOIT_SDK_SOURCE_DIR} ${TEST_FILE})
# The test is a script (in our case a cmake script) that calls `cmake --build ... --target test_cmake`.
# It will thus call the above targets indirectly.
add_test(
  NAME ${TEST_NAME}
  COMMAND ${CMAKE_COMMAND} -DBIN_DIR=${CMAKE_BINARY_DIR} -DINPUT_DIR=${CMAKE_TEST_INPUT_DIR} -P ${TEST_FILE}
)
