# Copyright (C) 2019 Toitware ApS.
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

# Creates a custom command to build ${TARGET} with correct dependencies.
function(ADD_TOIT_TARGET SOURCE TARGET DEP_FILE ENV)
  if (NOT DEFINED TOITC)
    set(TOITC "$ENV{TOITC}")
    if ("${TOITC}" STREQUAL "")
      # TOITC is normally set to the toit.compile executable.
      # However, for cross-compilation the compiler must be provided manually.
      message(FATAL_ERROR "TOITC not provided")
    endif()
  endif()
  if(POLICY CMP0116)
    cmake_policy(SET CMP0116 NEW)
  endif()
  add_custom_command(
    OUTPUT "${TARGET}"
    DEPFILE ${DEP_FILE}
    COMMAND ${CMAKE_COMMAND} -E env ${ENV} ASAN_OPTIONS=detect_leaks=false "${TOITC}" --dependency-file "${DEP_FILE}" --dependency-format ninja -w "${TARGET}" "${SOURCE}"
  )
endfunction(ADD_TOIT_TARGET)
