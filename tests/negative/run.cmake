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
if (NOT DEFINED LIB_DIR)
  message(FATAL_ERROR "Missing LIB_DIR argument")
endif()
if (NOT DEFINED NORMALIZE_GOLD)
  message(FATAL_ERROR "Missing NORMALIZE_GOLD argument")
endif()
if (NOT DEFINED TEST_ROOT)
  message(FATAL_ERROR "Missing TEST_ROOT argument")
endif()
if (NOT DEFINED TMP)
  message(FATAL_ERROR "Missing TMP argument")
endif()

if (NOT DEFINED GIT_VERSION)
  # GIT_VERSION is optional.
  set(GIT_VERSION "")
endif()

file(READ ${TEST} TEST_CONTENT)

if ("${TEST_CONTENT}" MATCHES "[\n]// TEST_FLAGS: ([^\n]*)[\n]")
  set(TEST_FLAGS ${CMAKE_MATCH_1})
  separate_arguments(TEST_FLAGS)
endif()

execute_process(
  COMMAND "${TOITVM}" ${TEST_FLAGS} -Xenable-asserts "-Xlib_path=${LIB_DIR}" "${TEST}"
  OUTPUT_VARIABLE STDOUT
  ERROR_VARIABLE STDERR
  RESULT_VARIABLE EXIT_CODE
)

# We can't guarantee that stdout and stderr appear in the right order (looking at you, Windows).
# Ensure that the stderr is after stdout to avoid diffs..
set(OUTPUT "${STDOUT}${STDERR}")

if ("${EXIT_CODE}" EQUAL 0)
  message(FATAL_ERROR "Didn't fail with non-zero exit code")
endif()

include(${NORMALIZE_GOLD})

NORMALIZE_GOLD("${OUTPUT}" "${TEST_ROOT}" "${GIT_VERSION}" NORMALIZED)

if ((DEFINED UPDATE_GOLD) OR (NOT "$ENV{TOIT_UPDATE_GOLD}" STREQUAL ""))
  file(WRITE ${GOLD} "${NORMALIZED}")
else()
  file(READ ${GOLD} GOLD_CONTENT)
  LOCALIZE_GOLD("${GOLD_CONTENT}" GOLD_CONTENT)
  if (NOT "${GOLD_CONTENT}" STREQUAL "${NORMALIZED}")
    string(RANDOM LENGTH 12 RND)
    set(TMP_OUT ${TMP}/OUTPUT_${RND})
    set(TMP_GOLD ${TMP}/GOLD_${RND})
    file(WRITE ${TMP_OUT} "${NORMALIZED}")
    file(WRITE ${TMP_GOLD} "${GOLD_CONTENT}")
    # Note that the call to 'diff' is only to help the developer. It is only called
    # if the test is already failing.
    execute_process(
      COMMAND diff -u ${TMP_GOLD} ${TMP_OUT}
    )
    message(FATAL_ERROR "Not equal")
  endif()
endif()
