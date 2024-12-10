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

list(APPEND TOIT_SKIP_TESTS
  # Requires a setup step.
  toit-protobuf/tests/all_types_test.toit
  health-external/downloads/toit-protobuf/tests/all_types_test.toit
  # Requires a tool to be built.
  toit-png-tools/tests/suite_unzip_test.toit
)

if ("${CMAKE_SYSTEM_NAME}" STREQUAL "Windows" OR "${CMAKE_SYSTEM_NAME}" STREQUAL "MSYS")
  list(APPEND TOIT_SKIP_TESTS
  )
endif()
