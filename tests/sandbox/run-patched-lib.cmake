# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by an MIT-style license that can be
# found in the lib/LICENSE file.

# Compiles PROGRAM for an untrusted container against a copy of the SDK's
# library (LIB_DIR) in which the text PATCH_FROM of core/collections.toit is
# replaced by PATCH_TO (a program's own core library is part of its image,
# so an untrusted program can change it), runs the snapshot with
# 'toit.run --untrusted' and ARGS, and checks the output against
# EXPECTED_OUTPUT (exit code 0).

file(REMOVE_RECURSE "${TMP}")
file(MAKE_DIRECTORY "${TMP}")
file(COPY "${LIB_DIR}/" DESTINATION "${TMP}/lib")
set(collections "${TMP}/lib/core/collections.toit")
file(READ "${collections}" text)
string(FIND "${text}" "${PATCH_FROM}" at)
if(at EQUAL -1)
  message(FATAL_ERROR "'${PATCH_FROM}' not found in core/collections.toit")
endif()
string(REPLACE "${PATCH_FROM}" "${PATCH_TO}" text "${text}")
file(WRITE "${collections}" "${text}")

set(SNAPSHOT "${TMP}/program.snapshot")
execute_process(
  COMMAND "${TOIT_RUN}" "-Xlib_path=${TMP}/lib" --untrusted -w "${SNAPSHOT}" "${PROGRAM}"
  RESULT_VARIABLE result
  )
if(NOT result EQUAL 0)
  message(FATAL_ERROR "Compiling ${PROGRAM} failed: ${result}")
endif()

execute_process(
  COMMAND "${TOIT_RUN}" --untrusted "${SNAPSHOT}" ${ARGS}
  RESULT_VARIABLE result
  OUTPUT_VARIABLE stdout
  ERROR_VARIABLE stderr
  )
set(output "${stdout}${stderr}")
message("${output}")
if(NOT result EQUAL 0)
  message(FATAL_ERROR "Expected exit code 0, got ${result}")
endif()
if(NOT output MATCHES "${EXPECTED_OUTPUT}")
  message(FATAL_ERROR "Output doesn't match '${EXPECTED_OUTPUT}'")
endif()
