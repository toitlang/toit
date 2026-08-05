# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by an MIT-style license that can be
# found in the lib/LICENSE file.

add_test(
  NAME tests/stdio/stdio-test
  COMMAND ${CMAKE_COMMAND}
      -DTOIT_RUN=$<TARGET_FILE:toit.run>
      -DTEST=${CMAKE_CURRENT_SOURCE_DIR}/stdio-test.toit
      -DINPUT=${CMAKE_CURRENT_SOURCE_DIR}/stdin.txt
      -DPROJECT_ROOT=${CMAKE_CURRENT_SOURCE_DIR}
      -P ${CMAKE_CURRENT_SOURCE_DIR}/run.cmake
  )

add_test(
  NAME tests/stdio/host-coexist-test
  COMMAND ${CMAKE_COMMAND}
      -DTOIT_RUN=$<TARGET_FILE:toit.run>
      -DTEST=${CMAKE_CURRENT_SOURCE_DIR}/host-coexist-test.toit
      -DINPUT=${CMAKE_CURRENT_SOURCE_DIR}/stdin.txt
      -DPROJECT_ROOT=${TOIT_SDK_SOURCE_DIR}/tests
      -P ${CMAKE_CURRENT_SOURCE_DIR}/run.cmake
  )
