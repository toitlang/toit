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

if (NOT DEFINED TOITC)
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
if (NOT DEFINED TEST_ROOT)
  message(FATAL_ERROR "Missing TEST_ROOT argument")
endif()
if (NOT DEFINED TMP)
  message(FATAL_ERROR "Missing TMP argument")
endif()

execute_process(
  COMMAND ${TOITC} --analyze --show-package-warnings "-Xlib_path=${LIB_DIR}" "${TEST}"
  OUTPUT_VARIABLE STDOUT
  ERROR_VARIABLE STDERR
  RESULT_VARIABLE EXIT_CODE
)

message("-Xlib_path=${LIB_DIR}")
message("${TEST}")

# We can't guarantee that stdout and stderr appear in the right order (looking at you, Windows).
# Ensure that the stderr is after stdout to avoid diffs..
set(OUTPUT "${STDOUT}${STDERR}")

include("${CMAKE_CURRENT_LIST_DIR}/normalize_gold.cmake")

NORMALIZE_GOLD("${OUTPUT}" "${TEST_ROOT}" "" NORMALIZED)

if ((DEFINED UPDATE_GOLD) OR (NOT "$ENV{TOIT_UPDATE_GOLD}" STREQUAL ""))
  if (NOT "${NORMALIZED}" STREQUAL "")
    # Only write a file if there was an output.
    message("Updated ${GOLD}")
    file(WRITE "${GOLD}" "${NORMALIZED}")
  endif()
else()
  if ("${NORMALIZED}" STREQUAL "")
    if (EXISTS "${GOLD}")
      message(FATAL_ERROR "Gold file for ${TEST} exists, but no output")
    endif()
  else()
    if (EXISTS "${GOLD}")
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
    else()
      message("${NORMALIZED}")
      message(FATAL_ERROR "Unexpected error")
    endif()
  endif()
endif()
