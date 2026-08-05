# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by an MIT-style license that can be
# found in the lib/LICENSE file.

execute_process(
  COMMAND "${TOIT_RUN}" --project-root "${PROJECT_ROOT}" "${TEST}"
  INPUT_FILE "${INPUT}"
  OUTPUT_VARIABLE ACTUAL_STDOUT
  ERROR_VARIABLE ACTUAL_STDERR
  RESULT_VARIABLE RESULT
  )

if(NOT RESULT EQUAL 0)
  message(FATAL_ERROR "stdio test failed with exit code ${RESULT}:\n${ACTUAL_STDERR}")
endif()

set(EXPECTED_STDOUT "stdout:hello from stdin\n")
set(EXPECTED_STDERR "stderr:hello from stdin\n")
if(NOT ACTUAL_STDOUT STREQUAL EXPECTED_STDOUT)
  message(FATAL_ERROR "unexpected stdout: '${ACTUAL_STDOUT}'")
endif()
if(NOT ACTUAL_STDERR STREQUAL EXPECTED_STDERR)
  message(FATAL_ERROR "unexpected stderr: '${ACTUAL_STDERR}'")
endif()
