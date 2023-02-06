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

if (NOT DEFINED TOIT_COMPILE)
  message(FATAL_ERROR "Missing TOIT_COMPILE argument")
endif()
if (NOT DEFINED TOIT_RUN)
  message(FATAL_ERROR "Missing TOIT_RUN argument")
endif()
if (NOT DEFINED INPUT)
  message(FATAL_ERROR "Missing INPUT argument")
endif()
if (NOT DEFINED SNAPSHOT)
  message(FATAL_ERROR "Missing SNAPSHOT argument")
endif()
if (NOT DEFINED VALGRIND_XML_PREFIX)
  message(FATAL_ERROR "Missing VALGRIND_XML_PREFIX argument")
endif()

# TODO: make this configurable.
find_program("VALGRIND" "valgrind")
if (NOT VALGRIND)
  message(FATAL_ERROR "Missing valgrind")
endif()

function(backtick)
  message("Running command " ${ARGN})
  execute_process(
    COMMAND ${ARGN}
    #COMMAND_ERROR_IS_FATAL ANY
  )
endfunction()

# Make sure the directory for the XML files exists.
get_filename_component(VALGRIND_XML_DIR ${VALGRIND_XML_PREFIX} DIRECTORY)
file(MAKE_DIRECTORY ${VALGRIND_XML_DIR})

set(VALGRIND_COMPILE_XML "${VALGRIND_XML_PREFIX}-compile.xml")
backtick(
  "${VALGRIND}"
      "--xml=yes" "--xml-file=${VALGRIND_COMPILE_XML}"
      "--show-leak-kinds=none"  # No leak check for the compilation.
      "${TOIT_COMPILE}" "-w" "${SNAPSHOT}" "${INPUT}"
)

set(VALGRIND_RUN_XML "${VALGRIND_XML_PREFIX}-run.xml")
backtick(
  "${VALGRIND}"
      "--xml=yes" "--xml-file=${VALGRIND_RUN_XML}"
      # TODO(florian): enable leak detection for the run.
      "--show-leak-kinds=none"
      "${TOIT_RUN}" "${SNAPSHOT}"
)

set(ERRORS_DETECTED FALSE)
function(check_valgrind_errors xml_file)
  file(READ ${xml_file} VALGRIND_OUTPUT)

  # Extract all lines of the form '<kind>...</kind>'.
  string(REGEX MATCHALL "<kind>[^<]*</kind>" VALGRIND_ERRORS "${VALGRIND_OUTPUT}")

  # If we have a line that is not a leak, fail.
  if (VALGRIND_ERRORS)
    set(ERRORS_DETECTED TRUE)
    message("Valgrind errors in ${xml_file}: ${VALGRIND_ERRORS}")
  endif()
endfunction()

check_valgrind_errors(${VALGRIND_COMPILE_XML})
check_valgrind_errors(${VALGRIND_RUN_XML})

if (ERRORS_DETECTED)
  message(FATAL_ERROR "Valgrind errors detected")
endif()
