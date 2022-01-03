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

set(TOOLS system_message snapshot_to_image inject_config)

foreach (TOOL ${TOOLS})
  set(TOOL_SNAPSHOT ${CMAKE_BINARY_DIR}/sdk/snapshots/${TOOL}.snapshot)

  ADD_TOIT_TARGET(
    ${CMAKE_CURRENT_SOURCE_DIR}/${TOOL}.toit
    ${TOOL_SNAPSHOT}
    ${CMAKE_CURRENT_BINARY_DIR}/${TOOL}.dep
    ""
  )

  set(SNAPSHOTS ${TOOL_SNAPSHOT} ${SNAPSHOTS})
endforeach ()

add_custom_target(
  build_tool_snapshots
  DEPENDS ${SNAPSHOTS}
)
add_dependencies(build_snapshots build_tool_snapshots)
