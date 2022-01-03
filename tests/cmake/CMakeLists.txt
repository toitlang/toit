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

# We use a directory with spaces to test that the dependency generation
# works in that case too.
set(CMAKE_INPUT "${CMAKE_CURRENT_SOURCE_DIR}/dir with spaces/input.toit")
set(SNAPSHOT "${CMAKE_BINARY_DIR}/cmake_test/cmake.snapshot")

ADD_TOIT_TARGET(
  ${CMAKE_INPUT}
  ${SNAPSHOT}
  "${SNAPSHOT}.dep"
  "")


# This test must be run by an external tool:
# 1. Create the cmake_input.toit file.
# 2. Generate the snapshot using the `build_cmake_snapshot` target first.
# 3. Test it with `test_cmake_snapshot`.
# 4. Modify the cmake_input.toit file (or one of its dependencies).
# 5. Generate the snapshot again.
# 6. Test again. (We need two runs to make sure that the dependency-mechanism works.)
add_custom_target(
  build_cmake_snapshot
  DEPENDS "${SNAPSHOT}"
)

set(CMAKE_SNAPSHOT_OUTPUT "${CMAKE_BINARY_DIR}/cmake_test/snapshot.out")
set(CMAKE_SOURCE_OUTPUT   "${CMAKE_BINARY_DIR}/cmake_test/source.out")

add_custom_command(
  OUTPUT ${CMAKE_SNAPSHOT_OUTPUT}
  COMMAND $<TARGET_FILE:toitvm> ${SNAPSHOT} > ${CMAKE_SNAPSHOT_OUTPUT}
  DEPENDS ${SNAPSHOT}
)

add_custom_command(
  OUTPUT ${CMAKE_SOURCE_OUTPUT}
  COMMAND $<TARGET_FILE:toitvm> ${CMAKE_INPUT} > ${CMAKE_SOURCE_OUTPUT}
  DEPENDS ${SNAPSHOT}
)

add_custom_target(
  test_cmake_snapshot
  COMMAND diff ${CMAKE_SNAPSHOT_OUTPUT} ${CMAKE_SOURCE_OUTPUT}
  DEPENDS ${CMAKE_SNAPSHOT_OUTPUT} ${CMAKE_SOURCE_OUTPUT}
)
