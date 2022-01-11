# Copyright (C) 2021 Toitware ApS. All rights reserved.

function(NORMALIZE_GOLD INPUT PREFIX_TO_REMOVE GIT_VERSION OUTPUT)
  file(TO_NATIVE_PATH "${PREFIX_TO_REMOVE}" PREFIX_TO_REMOVE)
  string(REPLACE "${PREFIX_TO_REMOVE}" "<...>" RESULT "${INPUT}")
  if (NOT "${GIT_VERSION}" STREQUAL "")
    string(REPLACE "${GIT_VERSION}" "<GIT_VERSION>" RESULT "${RESULT}")
  endif()
  set(${OUTPUT} "${RESULT}" PARENT_SCOPE)
endfunction()

function(LOCALIZE_GOLD INPUT OUTPUT)
  if (NOT "${CMAKE_SYSTEM_NAME}" STREQUAL "Windows")
    set(${OUTPUT} "${INPUT}" PARENT_SCOPE)
    return()
  endif()

  # Find all potential paths and replace them.
  string(REGEX MATCHALL "(/?tests[a-zA-Z_0-9/]+)|([a-zA-Z_0-9/]+[.]toit)" PATHS "${INPUT}")
  list(REMOVE_DUPLICATES PATHS)
  # In case one path is a prefix of the other have the longer one be handled first.
  list(SORT PATHS ORDER DESCENDING)
  set(RESULT "${INPUT}")
  foreach(PATH ${PATHS})
    string(REPLACE "/" "\\" REPLACEMENT "${PATH}")
    string(REPLACE "${PATH}" "${REPLACEMENT}" RESULT "${RESULT}")
  endforeach()

  set(${OUTPUT} "${RESULT}" PARENT_SCOPE)
endfunction()
