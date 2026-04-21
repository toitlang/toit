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

# Gold-file test runner for the formatter.
# - Takes an INPUT .toit file, copies it to a tmp file, runs `toit format`
#   on the tmp copy, then compares the formatted bytes to a GOLD file.
# - If UPDATE_GOLD is set (or the TOIT_UPDATE_GOLD env var is non-empty),
#   the tmp's contents are written to GOLD instead. That's how to
#   regenerate golds after intentional formatter changes.
# - Also checks idempotence: re-format the gold output and assert no
#   further change. This catches any rule that produces different output
#   on its own output.
# - The MODE argument selects the formatter mode:
#     MODE=normal → default (no env var).
#     MODE=flat   → sets TOIT_FORMAT_FLAT_TEST=1 for the subprocess.

if (NOT DEFINED TOIT)
  message(FATAL_ERROR "Missing TOIT argument")
endif()
if (NOT DEFINED INPUT)
  message(FATAL_ERROR "Missing INPUT argument")
endif()
if (NOT DEFINED GOLD)
  message(FATAL_ERROR "Missing GOLD argument")
endif()
if (NOT DEFINED TMP)
  message(FATAL_ERROR "Missing TMP argument")
endif()
if (NOT DEFINED MODE)
  set(MODE "normal")
endif()

string(RANDOM LENGTH 12 RND)
set(TMP_FILE "${TMP}/fmt_${RND}.toit")

file(READ "${INPUT}" INPUT_CONTENT)
file(WRITE "${TMP_FILE}" "${INPUT_CONTENT}")

if (MODE STREQUAL "flat")
  set(ENV{TOIT_FORMAT_FLAT_TEST} "1")
endif()

execute_process(
  COMMAND "${TOIT}" format "${TMP_FILE}"
  OUTPUT_VARIABLE STDOUT
  ERROR_VARIABLE STDERR
  RESULT_VARIABLE EXIT_CODE
)

if (NOT "${EXIT_CODE}" EQUAL 0)
  message(FATAL_ERROR "Formatter failed on ${INPUT}:\n${STDERR}")
endif()

file(READ "${TMP_FILE}" FORMATTED)

if ((DEFINED UPDATE_GOLD) OR (NOT "$ENV{TOIT_UPDATE_GOLD}" STREQUAL ""))
  file(WRITE "${GOLD}" "${FORMATTED}")
  message(STATUS "Wrote gold ${GOLD}")
  return()
endif()

if (NOT EXISTS "${GOLD}")
  message(FATAL_ERROR "Gold file missing: ${GOLD}\nRun with -DUPDATE_GOLD=true or TOIT_UPDATE_GOLD=1 env var to create it.")
endif()

file(READ "${GOLD}" GOLD_CONTENT)
if (NOT "${GOLD_CONTENT}" STREQUAL "${FORMATTED}")
  set(DIFF_OUT "${TMP}/fmt_${RND}_diff_out")
  file(WRITE "${DIFF_OUT}" "${FORMATTED}")
  execute_process(
    COMMAND diff -u "${GOLD}" "${DIFF_OUT}"
  )
  message(FATAL_ERROR "Formatter output did not match gold: ${GOLD}")
endif()

# Idempotence: reformat the gold-matching output. Must not change.
execute_process(
  COMMAND "${TOIT}" format "${TMP_FILE}"
  OUTPUT_VARIABLE STDOUT2
  ERROR_VARIABLE STDERR2
  RESULT_VARIABLE EXIT_CODE2
)
if (NOT "${EXIT_CODE2}" EQUAL 0)
  message(FATAL_ERROR "Formatter failed on idempotence re-run: ${STDERR2}")
endif()

file(READ "${TMP_FILE}" REFORMATTED)
if (NOT "${REFORMATTED}" STREQUAL "${FORMATTED}")
  set(DIFF_ONCE "${TMP}/fmt_${RND}_once")
  set(DIFF_TWICE "${TMP}/fmt_${RND}_twice")
  file(WRITE "${DIFF_ONCE}" "${FORMATTED}")
  file(WRITE "${DIFF_TWICE}" "${REFORMATTED}")
  execute_process(
    COMMAND diff -u "${DIFF_ONCE}" "${DIFF_TWICE}"
  )
  message(FATAL_ERROR "Formatter not idempotent on ${INPUT}")
endif()
