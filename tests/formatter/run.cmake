# Copyright (C) 2026 Toit contributors.

foreach(argument TOIT INPUT GOLD TMP)
  if (NOT DEFINED ${argument})
    message(FATAL_ERROR "Missing ${argument} argument")
  endif()
endforeach()

string(RANDOM LENGTH 12 random_suffix)
set(tmp_file "${TMP}/formatter_${random_suffix}.toit")
file(READ "${INPUT}" input_content)
file(WRITE "${tmp_file}" "${input_content}")

execute_process(
  COMMAND "${TOIT}" format "${tmp_file}"
  OUTPUT_VARIABLE stdout
  ERROR_VARIABLE stderr
  RESULT_VARIABLE exit_code
)
if (NOT "${exit_code}" EQUAL 0)
  message(FATAL_ERROR "Formatter failed on ${INPUT}:\n${stdout}${stderr}")
endif()
file(READ "${tmp_file}" formatted)

if ((DEFINED UPDATE_GOLD) OR (NOT "$ENV{TOIT_UPDATE_GOLD}" STREQUAL ""))
  file(WRITE "${GOLD}" "${formatted}")
  return()
endif()

file(READ "${GOLD}" expected)
if (NOT "${expected}" STREQUAL "${formatted}")
  set(actual "${TMP}/formatter_${random_suffix}.actual")
  file(WRITE "${actual}" "${formatted}")
  execute_process(COMMAND diff -u "${GOLD}" "${actual}")
  message(FATAL_ERROR "Formatter output did not match ${GOLD}")
endif()

execute_process(
  COMMAND "${TOIT}" format "${tmp_file}"
  OUTPUT_VARIABLE stdout
  ERROR_VARIABLE stderr
  RESULT_VARIABLE exit_code
)
if (NOT "${exit_code}" EQUAL 0)
  message(FATAL_ERROR "Formatter failed its idempotence pass: ${stderr}")
endif()
file(READ "${tmp_file}" reformatted)
if (NOT "${reformatted}" STREQUAL "${formatted}")
  message(FATAL_ERROR "Formatter is not idempotent on ${INPUT}")
endif()
