# Copyright (C) 2024 Toitware ApS.
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

set(TOIT_SKIP_TESTS
)
if (DEFINED ENV{TOIT_CHECK_PROPAGATED_TYPES})
  list(APPEND TOIT_SKIP_TESTS
    # This test takes too long.
    tests/envelope/boot-upgrade-test.toit
  )
endif()

if ("${CMAKE_SYSTEM_NAME}" STREQUAL "Windows" OR "${CMAKE_SYSTEM_NAME}" STREQUAL "MSYS")
  list(APPEND TOIT_SKIP_TESTS
    # Windows doesn't support permanent flash yet.
    tests/envelope/boot-flash-test.toit
    # Windows doesn't have any way to send a "TERM" signal.
    tests/envelope/boot-kill-test.toit
  )
endif()
