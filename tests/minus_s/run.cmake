# Copyright (C) 2021 Toitware ApS. All rights reserved.

if (NOT DEFINED TOITVM)
  message(FATAL_ERROR "Missing TOITVM argument")
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

file(READ "${TEST}" TEST_CONTENT)
string(STRIP "${TEST_CONTENT}" TEST_CONTENT)

execute_process(
  COMMAND "${TOITVM}" -Xenable-asserts -s "${TEST_CONTENT}"
  OUTPUT_VARIABLE STDOUT
  ERROR_VARIABLE STDERR
  RESULT_VARIABLE EXIT_CODE
)

# We can't guarantee that stdout and stderr appear in the right order (looking at you, Windows).
# Ensure that the stderr is after stdout to avoid diffs..
set(OUTPUT "Exit Code: ${EXIT_CODE}
${STDOUT}${STDERR}")

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
