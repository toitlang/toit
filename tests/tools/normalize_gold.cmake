# Copyright (C) 2021 Toitware ApS. All rights reserved.

function(NORMALIZE_GOLD INPUT PREFIX_TO_REMOVE GIT_VERSION OUTPUT)
  string(REPLACE "${PREFIX_TO_REMOVE}" "<...>" RESULT "${INPUT}")
  if (NOT "${GIT_VERSION}" STREQUAL "")
    string(REPLACE "${GIT_VERSION}" "<GIT_VERSION>" RESULT "${RESULT}")
  endif()
  set(${OUTPUT} ${RESULT} PARENT_SCOPE)
endfunction()
