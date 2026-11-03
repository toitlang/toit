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

# Copies the sources of the system program into the SDK, so applications can
# be compiled into it. The layout is the one of the repository, because the
# sources import each other with relative paths. The packages of the host
# system program are put where its package lock looks for them first.
#
# Takes SOURCE_DIR (the root of the repository) and TARGET_DIR.

if (NOT DEFINED SOURCE_DIR OR NOT DEFINED TARGET_DIR)
  message(FATAL_ERROR "Missing SOURCE_DIR or TARGET_DIR")
endif()

file(REMOVE_RECURSE "${TARGET_DIR}")
file(COPY "${SOURCE_DIR}/system" DESTINATION "${TARGET_DIR}"
  PATTERN ".packages" EXCLUDE
  PATTERN ".packages-bootstrap" EXCLUDE
)
foreach(tool mirror.toit snapshot.toit system-message_.toit)
  file(COPY "${SOURCE_DIR}/tools/${tool}" DESTINATION "${TARGET_DIR}/tools")
endforeach()
file(COPY "${SOURCE_DIR}/system/extensions/host/.packages-bootstrap/"
  DESTINATION "${TARGET_DIR}/system/extensions/host/.packages"
)
