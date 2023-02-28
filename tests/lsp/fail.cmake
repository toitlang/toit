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


if ("${CMAKE_SYSTEM_NAME}" STREQUAL "Windows" OR "${CMAKE_SYSTEM_NAME}" STREQUAL "MSYS")
  list(APPEND TOIT_FAILING_TESTS
    tests/lsp/dump_crash_compiler_test.toit
    tests/lsp/timeout_compiler_test.toit
  )
  set(TOIT_SKIP_TESTS
    # Currently times out.
    # Most likely because signals aren't handled correctly on Windows.
    tests/lsp/crash_compiler_test.toit
    tests/lsp/crash_rate_limit_compiler_test.toit
    tests/lsp/error_compiler_test.toit
    tests/lsp/mock_compiler_test_slow.toit

    # floitsch: not entirely sure why this test fails on Windows.
    tests/lsp/repro_compiler_test_slow.toit
  )
endif()
