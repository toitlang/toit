# Copyright (C) 2022 Toitware ApS.
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

# Several checks that the snapshot-to-image and image-run work.

if (NOT DEFINED SNAP)
  message(FATAL_ERROR "Missing SNAP argument")
endif()
if (NOT DEFINED OUTPUT_PREFIX)
  message(FATAL_ERROR "Missing OUTPUT_PREFIX argument")
endif()
if (NOT DEFINED TOITC)
  message(FATAL_ERROR "Missing TOITC argument")
endif()
if (NOT DEFINED TOITVM)
  message(FATAL_ERROR "Missing TOITVM argument")
endif()
if (NOT DEFINED ASM)
  message(FATAL_ERROR "Missing ASM argument")
endif()
if (NOT DEFINED SNAPSHOT_TO_IMAGE)
  message(FATAL_ERROR "Missing SNAPSHOT_TO_IMAGE argument")
endif()
if (NOT DEFINED RUN_IMAGE)
  message(FATAL_ERROR "Missing RUN_IMAGE argument")
endif()
if (NOT DEFINED EXPECTED_OUT)
  message(FATAL_ERROR "Missing EXPECTED_OUT argument")
endif()
if (NOT DEFINED WORKING_DIR)
  message(FATAL_ERROR "Missing WORKING_DIR argument")
endif()

function (run_and_check IMAGE)
  execute_process(
    COMMAND "${RUN_IMAGE}" "${IMAGE}"
    OUTPUT_VARIABLE STDOUT
    WORKING_DIRECTORY "${WORKING_DIR}"
    COMMAND_ERROR_IS_FATAL ANY
  )
  file(READ "${EXPECTED_OUT}" EXPECTED)
  if (NOT "${STDOUT}" STREQUAL "${EXPECTED}")
    message(FATAL_ERROR "Unexpected output")
  endif()
endfunction()

set(IMAGE_S2I "${OUTPUT_PREFIX}-s2i.image")
set(IMAGE_S "${OUTPUT_PREFIX}-s2i.s")
set(IMAGE_O "${OUTPUT_PREFIX}-s2i.o")

# Compile the snapshot to an image using the toit tool.
execute_process(
  COMMAND "${TOITVM}" "${SNAPSHOT_TO_IMAGE}" -o "${IMAGE_S}" "${SNAP}"
  WORKING_DIRECTORY "${WORKING_DIR}"
  COMMAND_ERROR_IS_FATAL ANY
  )

# Only try to assemble on Linux.
# We are going to use the esp32-assembler anyways, so no need to
# check on all platforms.
if (DEFINED UNIX AND NOT DEFINED APPLE)
  # Check that the s file can be compiled with the assembler.
  execute_process(
    COMMAND "${ASM}" -c -o "${IMAGE_O}" "${IMAGE_S}"
    WORKING_DIRECTORY "${WORKING_DIR}"
    COMMAND_ERROR_IS_FATAL ANY
    )
endif()

# Compile to binary image.
execute_process(
  COMMAND "${TOITVM}" "${SNAPSHOT_TO_IMAGE}" --binary -o "${IMAGE_S2I}" "${SNAP}"
  WORKING_DIRECTORY "${WORKING_DIR}"
  COMMAND_ERROR_IS_FATAL ANY
  )

# Run it and verify that the output is as expected.
run_and_check("${IMAGE_S2I}")
