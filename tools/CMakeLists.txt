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

include(toit.cmake)

set(TOOLS firmware system_message snapshot_to_image inject_config toitp stacktrace)
set(EXES)

foreach (TOOL ${TOOLS})
  set(TOOL_EXE ${CMAKE_BINARY_DIR}/sdk/tools/${TOOL}${CMAKE_EXECUTABLE_SUFFIX})

  ADD_TOIT_EXE(
    ${CMAKE_CURRENT_SOURCE_DIR}/${TOOL}.toit
    ${TOOL_EXE}
    ${CMAKE_CURRENT_BINARY_DIR}/${TOOL}.exe.dep
    ""
  )

  list(APPEND EXES "${TOOL_EXE}")
endforeach ()

add_custom_target(
  build_toit_tools
  DEPENDS ${EXES}
)

toit_project(lsp "${CMAKE_CURRENT_LIST_DIR}/lsp/server")
toit_project(tools "${CMAKE_CURRENT_LIST_DIR}")
