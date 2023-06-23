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
)

if ("${CMAKE_SYSTEM_NAME}" STREQUAL "Windows" OR "${CMAKE_SYSTEM_NAME}" STREQUAL "MSYS")
  list(APPEND TOIT_SKIP_TESTS
    # Temporarely disable fork tests on Windows.
    # See https://github.com/toitlang/pkg-host/issues/47
    pkg-host/tests/fork_stress_test_slow.toit
    pkg-host/tests/pipe2_test.toit
  )
endif()
