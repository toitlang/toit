# Copyright (C) 2023 Toitware ApS.
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

if (NOT DEFINED TOITVM)
  message(FATAL_ERROR "Missing TOITVM argument")
endif()
if (NOT DEFINED TEST)
  message(FATAL_ERROR "Missing TEST argument")
endif()
if (NOT DEFINED VALGRIND_XML)
  message(FATAL_ERROR "Missing VALGRIND_XML argument")
endif()

# TODO: make this configurable.
find_program("VALGRIND" "valgrind")
if (NOT VALGRIND)
  message(FATAL_ERROR "Missing valgrind")
endif()

execute_process(
  COMMAND "${VALGRIND}" "--xml=yes" "--xml-file=${VALGRIND_XML}" "${TOITVM}" "${TEST}"
  OUTPUT_VARIABLE STDOUT
  ERROR_VARIABLE STDERR
  RESULT_VARIABLE EXIT_CODE
)

file(READ ${VALGRIND_XML} VALGRIND_OUTPUT)

# Extract all lines of the form '<kind>...</kind>'.
string(REGEX MATCHALL "<kind>[^<]*</kind>" VALGRIND_ERRORS "${VALGRIND_OUTPUT}")

# Filter out lines that contain "Leak_".
list(FILTER VALGRIND_ERRORS EXCLUDE REGEX "Leak_")

# If we have a line that is not a leak, fail.
if (VALGRIND_ERRORS)
  message(FATAL_ERROR "Valgrind errors: ${VALGRIND_ERRORS}")
endif()
