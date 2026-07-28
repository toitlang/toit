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

if (NOT DEFINED TOIT)
  message(FATAL_ERROR "Missing TOIT argument")
endif()

string(RANDOM LENGTH 12 RANDOM_SUFFIX)
set(READ_ONLY_FILE "${TMP}/fmt_read_only_${RANDOM_SUFFIX}.toit")
file(READ "${INPUT}" ORIGINAL)
file(WRITE "${READ_ONLY_FILE}" "${ORIGINAL}")
file(CHMOD "${READ_ONLY_FILE}"
     PERMISSIONS OWNER_READ GROUP_READ WORLD_READ)

execute_process(
  COMMAND "${TOIT}" format "${READ_ONLY_FILE}"
  RESULT_VARIABLE EXIT_CODE
  OUTPUT_VARIABLE STDOUT
  ERROR_VARIABLE STDERR)

if ("${EXIT_CODE}" EQUAL 0)
  message(FATAL_ERROR "Formatting a read-only file unexpectedly succeeded")
endif()

file(READ "${READ_ONLY_FILE}" AFTER)
if (NOT "${AFTER}" STREQUAL "${ORIGINAL}")
  message(FATAL_ERROR "Formatting failure changed the read-only file")
endif()
