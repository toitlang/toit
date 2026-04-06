# Copyright (C) 2026 Toit contributors.
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

# Idempotency test: format every .toit file in TOIT_SDK_SOURCE_DIR/lib twice
# and verify the second pass doesn't change the output. Any failure means the
# formatter is not idempotent — a correctness bug.

if (NOT DEFINED TOIT_COMPILE)
  message(FATAL_ERROR "Missing TOIT_COMPILE argument")
endif()
if (NOT DEFINED LIB_DIR)
  message(FATAL_ERROR "Missing LIB_DIR argument")
endif()
if (NOT DEFINED TMP)
  message(FATAL_ERROR "Missing TMP argument")
endif()

file(GLOB_RECURSE LIB_FILES "${LIB_DIR}/*.toit")

set(FAILURES "")
foreach(lib_file ${LIB_FILES})
  string(RANDOM LENGTH 12 RND)
  set(TMP_COPY "${TMP}/IDEMPOTENCY_${RND}.toit")
  configure_file("${lib_file}" "${TMP_COPY}" COPYONLY)

  # Pass 1.
  execute_process(
    COMMAND "${TOIT_COMPILE}" --format "${TMP_COPY}"
    RESULT_VARIABLE EXIT1
    ERROR_VARIABLE STDERR1
  )
  if (NOT "${EXIT1}" EQUAL 0)
    list(APPEND FAILURES "FORMAT-FAIL (pass 1): ${lib_file}: ${STDERR1}")
    continue()
  endif()
  file(READ "${TMP_COPY}" PASS1_CONTENT)

  # Pass 2.
  execute_process(
    COMMAND "${TOIT_COMPILE}" --format "${TMP_COPY}"
    RESULT_VARIABLE EXIT2
    ERROR_VARIABLE STDERR2
  )
  if (NOT "${EXIT2}" EQUAL 0)
    list(APPEND FAILURES "FORMAT-FAIL (pass 2): ${lib_file}: ${STDERR2}")
    continue()
  endif()
  file(READ "${TMP_COPY}" PASS2_CONTENT)

  if (NOT "${PASS1_CONTENT}" STREQUAL "${PASS2_CONTENT}")
    list(APPEND FAILURES "NOT-IDEMPOTENT: ${lib_file}")
    # Also save the diff for inspection.
    set(PASS1_FILE "${TMP}/IDEMPOTENCY_PASS1_${RND}")
    set(PASS2_FILE "${TMP}/IDEMPOTENCY_PASS2_${RND}")
    file(WRITE "${PASS1_FILE}" "${PASS1_CONTENT}")
    file(WRITE "${PASS2_FILE}" "${PASS2_CONTENT}")
    execute_process(COMMAND diff -u "${PASS1_FILE}" "${PASS2_FILE}")
  endif()
endforeach()

list(LENGTH FAILURES NUM_FAILURES)
if (NUM_FAILURES GREATER 0)
  foreach(failure ${FAILURES})
    message("${failure}")
  endforeach()
  message(FATAL_ERROR "${NUM_FAILURES} file(s) failed the idempotency check")
endif()

message("Idempotency check passed for all files in ${LIB_DIR}")
