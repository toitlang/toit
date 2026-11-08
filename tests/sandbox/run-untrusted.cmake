# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by an MIT-style license that can be
# found in the lib/LICENSE file.

# Runs PROGRAM with 'toit.run --untrusted', either from source or compiled
# to a snapshot first (MODE), and checks the exit code and the output.

if(MODE STREQUAL "snapshot")
  file(MAKE_DIRECTORY "${TMP}")
  set(SNAPSHOT "${TMP}/program.snapshot")
  execute_process(
    COMMAND "${TOIT_RUN}" -w "${SNAPSHOT}" "${PROGRAM}"
    RESULT_VARIABLE result
    )
  if(NOT result EQUAL 0)
    message(FATAL_ERROR "Compiling ${PROGRAM} failed: ${result}")
  endif()
  set(TARGET "${SNAPSHOT}")
else()
  set(TARGET "${PROGRAM}")
endif()

execute_process(
  COMMAND "${TOIT_RUN}" --untrusted "${TARGET}"
  RESULT_VARIABLE result
  OUTPUT_VARIABLE stdout
  ERROR_VARIABLE stderr
  )

set(output "${stdout}${stderr}")
message("${output}")

if(NOT result EQUAL EXPECTED_EXIT)
  message(FATAL_ERROR "Expected exit code ${EXPECTED_EXIT}, got ${result}")
endif()

if(NOT output MATCHES "${EXPECTED_OUTPUT}")
  message(FATAL_ERROR "Output doesn't match '${EXPECTED_OUTPUT}'")
endif()
