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

if (NOT DEFINED TOIT_COMPILE)
  message(FATAL_ERROR "Missing TOIT_COMPILE argument")
endif()
if (NOT DEFINED TEST)
  message(FATAL_ERROR "Missing TEST argument")
endif()
if (NOT DEFINED GOLD)
  message(FATAL_ERROR "Missing GOLD argument")
endif()
if (NOT DEFINED TMP)
  message(FATAL_ERROR "Missing TMP argument")
endif()

file(READ ${TEST} TEST_CONTENT)

# Execute toit.compile --format over the input file.
# The `toit.compile` writes the output back to the file if the `out_path` is the same.
# We will copy the file to a tmp path, format it there, and compare.

string(RANDOM LENGTH 12 RND)
set(TMP_INPUT ${TMP}/FORMAT_IN_${RND}.toit)
file(WRITE ${TMP_INPUT} "${TEST_CONTENT}")

execute_process(
  COMMAND "${TOIT_COMPILE}" --format "${TMP_INPUT}"
  OUTPUT_VARIABLE STDOUT
  ERROR_VARIABLE STDERR
  RESULT_VARIABLE EXIT_CODE
)

if (NOT "${EXIT_CODE}" EQUAL 0)
  message(FATAL_ERROR "Formatter failed with exit code ${EXIT_CODE}. stderr: ${STDERR}")
endif()

# We expect the file to be rewritten.
file(READ ${TMP_INPUT} FORMATTED_CONTENT)

# Idempotency check: formatting the already-formatted output must produce
# the same output. Format again and verify.
execute_process(
  COMMAND "${TOIT_COMPILE}" --format "${TMP_INPUT}"
  OUTPUT_VARIABLE STDOUT2
  ERROR_VARIABLE STDERR2
  RESULT_VARIABLE EXIT_CODE2
)
if (NOT "${EXIT_CODE2}" EQUAL 0)
  message(FATAL_ERROR "Second format failed with exit code ${EXIT_CODE2}. stderr: ${STDERR2}")
endif()
file(READ ${TMP_INPUT} FORMATTED_CONTENT2)
if (NOT "${FORMATTED_CONTENT}" STREQUAL "${FORMATTED_CONTENT2}")
  set(TMP_PASS1 ${TMP}/IDEMPOTENCY_PASS1_${RND})
  set(TMP_PASS2 ${TMP}/IDEMPOTENCY_PASS2_${RND})
  file(WRITE ${TMP_PASS1} "${FORMATTED_CONTENT}")
  file(WRITE ${TMP_PASS2} "${FORMATTED_CONTENT2}")
  execute_process(COMMAND diff -u ${TMP_PASS1} ${TMP_PASS2})
  message(FATAL_ERROR "Formatter is not idempotent — second pass changed the output")
endif()

if ((DEFINED UPDATE_GOLD) OR (NOT "$ENV{TOIT_UPDATE_GOLD}" STREQUAL ""))
  file(WRITE ${GOLD} "${FORMATTED_CONTENT}")
else()
  if (NOT EXISTS ${GOLD})
    message(FATAL_ERROR "No gold file found at ${GOLD}. Run `ninja update_formatter_gold`.")
  endif()
  file(READ ${GOLD} GOLD_CONTENT)
  if (NOT "${GOLD_CONTENT}" STREQUAL "${FORMATTED_CONTENT}")
    set(TMP_OUT ${TMP}/OUTPUT_${RND})
    set(TMP_GOLD ${TMP}/GOLD_${RND})
    file(WRITE ${TMP_OUT} "${FORMATTED_CONTENT}")
    file(WRITE ${TMP_GOLD} "${GOLD_CONTENT}")
    # Note that the call to 'diff' is only to help the developer. It is only called
    # if the test is already failing.
    execute_process(
      COMMAND diff -u ${TMP_GOLD} ${TMP_OUT}
    )
    message(FATAL_ERROR "Output format does not match gold expectations")
  endif()
endif()
