# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by an MIT-style license that can be
# found in the lib/LICENSE file.

# Copies the SDK's library next to TOIT_RUN to TMP, takes the boundary checks
# out of StringSlice_'s constructor (a program's own library need not have
# them), compiles PROGRAM against that library for an untrusted container
# (-Xlib_path) and runs the snapshot with 'toit.run --untrusted'. The output
# must match EXPECTED_OUTPUT and not UNEXPECTED_OUTPUT.

get_filename_component(BIN_DIR "${TOIT_RUN}" DIRECTORY)
# The SDK's lib is a link to the source tree's lib: copy the directory it
# names, never write through the link.
file(REAL_PATH "${BIN_DIR}/../lib" SDK_LIB)
file(REMOVE_RECURSE "${TMP}")
file(MAKE_DIRECTORY "${TMP}/lib")
file(COPY "${SDK_LIB}/" DESTINATION "${TMP}/lib")
if(IS_SYMLINK "${TMP}/lib" OR IS_SYMLINK "${TMP}/lib/core" OR IS_SYMLINK "${TMP}/lib/core/string.toit")
  message(FATAL_ERROR "the copy of the library is a link")
endif()

set(STRING_TOIT "${TMP}/lib/core/string.toit")
file(READ "${STRING_TOIT}" content)
set(CHECKS "    if from_ != size and ((str_.raw-at_ from_) & 0b1100_0000) == 0b1000_0000:
      throw \"ILLEGAL_UTF_8\"
    if to_ != size and ((str_.raw-at_ to_) & 0b1100_0000) == 0b1000_0000:
      throw \"ILLEGAL_UTF_8\"
")
string(REPLACE "${CHECKS}" "" patched "${content}")
if("${patched}" STREQUAL "${content}")
  message(FATAL_ERROR "StringSlice_'s boundary checks not found in ${STRING_TOIT}")
endif()
file(WRITE "${STRING_TOIT}" "${patched}")

set(SNAPSHOT "${TMP}/program.snapshot")
execute_process(
  COMMAND "${TOIT_RUN}" --untrusted "-Xlib_path=${TMP}/lib" -w "${SNAPSHOT}" "${PROGRAM}"
  RESULT_VARIABLE result
  )
if(NOT result EQUAL 0)
  message(FATAL_ERROR "Compiling ${PROGRAM} failed: ${result}")
endif()

execute_process(
  COMMAND "${TOIT_RUN}" --untrusted "${SNAPSHOT}"
  RESULT_VARIABLE result
  OUTPUT_VARIABLE stdout
  ERROR_VARIABLE stderr
  )
set(output "${stdout}${stderr}")
message("${output}")
if(NOT result EQUAL 0)
  message(FATAL_ERROR "Expected exit code 0, got ${result}")
endif()
if(NOT output MATCHES "${EXPECTED_OUTPUT}")
  message(FATAL_ERROR "Output doesn't match '${EXPECTED_OUTPUT}'")
endif()
