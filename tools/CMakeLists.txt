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

toit_project(lsp "${CMAKE_CURRENT_LIST_DIR}/lsp/server")
toit_project(tools "${CMAKE_CURRENT_LIST_DIR}")
toit_project(pkg "${CMAKE_CURRENT_LIST_DIR}/pkg")
