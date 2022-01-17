# Copyright (C) 2021 Toitware ApS.
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

set(TOIT_FAILING_TESTS
)

if ("${CMAKE_SYSTEM_NAME}" STREQUAL "Windows" OR "XX${CMAKE_SYSTEM_NAME}" STREQUAL "XXMSYS")
  list(APPEND TOIT_FAILING_TESTS
    tests/lock_file/basic_test
    tests/lock_file/dot_out_test
    tests/lock_file/empty_test
    tests/lock_file/multi_test
    tests/lock_file/sdk_version_test
  )
endif()
