# Copyright (C) 2022 Toitware ApS.
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

if (NOT DEFINED TOIT_VM)
  message(FATAL_ERROR "Missing TOIT_VM argument")
endif()
if (NOT DEFINED TOIT_COMPILE)
  message(FATAL_ERROR "Missing TOIT_COMPILE argument")
endif()
if (NOT DEFINED TEST)
  message(FATAL_ERROR "Missing TEST argument")
endif()
if (NOT DEFINED TEST_NAME)
  message(FATAL_ERROR "Missing TEST_NAME argument")
endif()
if (NOT DEFINED GOLD)
  message(FATAL_ERROR "Missing GOLD argument")
endif()
if (NOT DEFINED TEST_ROOT)
  message(FATAL_ERROR "Missing TEST_ROOT argument")
endif()
if (NOT DEFINED TMP)
  message(FATAL_ERROR "Missing TMP argument")
endif()

set(TMP_SNAPSHOT "${TMP}/${TEST_NAME}.snapshot")
set(TMP_TYPES "${TMP}/${TEST_NAME}.types")

execute_process(
  COMMAND "${TOIT_COMPILE}" -w "${TMP_SNAPSHOT}" -Xpropagate "${TEST}"
  OUTPUT_VARIABLE STDOUT
  RESULT_VARIABLE EXIT_CODE
)

if (NOT ("${EXIT_CODE}" EQUAL 0))
  message(FATAL_ERROR "Propagating types failed with exit code ${EXIT_CODE}.")
endif()

file(WRITE "${TMP_TYPES}" "${STDOUT}")

execute_process(
  COMMAND "${TOIT_VM}" "${TEST_ROOT}/tools/dump_types.toit" -s "${TMP_SNAPSHOT}" -t "${TMP_TYPES}"
  OUTPUT_VARIABLE STDOUT
  ERROR_VARIABLE STDERR
  RESULT_VARIABLE EXIT_CODE
)

# We can't guarantee that stdout and stderr appear in the right order (looking at you, Windows).
# Ensure that the stderr is after stdout to avoid diffs..
set(OUTPUT "${STDOUT}${STDERR}")

if (NOT "${EXIT_CODE}" EQUAL 0)
  message(FATAL_ERROR "Dumping the types failed with exit code ${EXIT_CODE}.")
endif()

if ((DEFINED UPDATE_GOLD) OR (NOT "$ENV{TOIT_UPDATE_GOLD}" STREQUAL ""))
  file(WRITE ${GOLD} "${OUTPUT}")
else()
  file(READ ${GOLD} GOLD_CONTENT)
  if (NOT "${GOLD_CONTENT}" STREQUAL "${OUTPUT}")
    string(RANDOM LENGTH 12 RND)
    set(TMP_OUT ${TMP}/OUTPUT_${RND})
    set(TMP_GOLD ${TMP}/GOLD_${RND})
    file(WRITE ${TMP_OUT} "${OUTPUT}")
    file(WRITE ${TMP_GOLD} "${GOLD_CONTENT}")
    # Note that the call to 'diff' is only to help the developer. It is only called
    # if the test is already failing.
    execute_process(
      COMMAND diff -u ${TMP_GOLD} ${TMP_OUT}
    )
    message(FATAL_ERROR "Not equal")
  endif()
endif()
