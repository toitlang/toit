# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

# Checks that a benchmark that is compiled to native code prints the expected output.

execute_process(
  COMMAND "${EXECUTABLE}"
  OUTPUT_VARIABLE OUTPUT
  COMMAND_ERROR_IS_FATAL ANY
)
file(READ "${GOLD}" EXPECTED)
if (NOT "${OUTPUT}" STREQUAL "${EXPECTED}")
  message(FATAL_ERROR "Unexpected output:\n${OUTPUT}\nExpected:\n${EXPECTED}")
endif()
