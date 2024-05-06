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

set(TOIT_SERIAL_TESTS
  tests/lsp/lsp-stress-compiler-test-slow.toit
)

if ("${CMAKE_SYSTEM_NAME}" STREQUAL "Windows" OR "${CMAKE_SYSTEM_NAME}" STREQUAL "MSYS")
  list(APPEND TOIT_FAILING_TESTS
    tests/lsp/dump-crash-compiler-test.toit
    tests/lsp/timeout-compiler-test.toit
  )
  set(TOIT_SKIP_TESTS
    # Currently times out.
    # Most likely because signals aren't handled correctly on Windows.
    tests/lsp/crash-compiler-test.toit
    tests/lsp/crash-rate-limit-compiler-test.toit
    tests/lsp/error-compiler-test.toit
    tests/lsp/mock-compiler-test-slow.toit

    # floitsch: not entirely sure why this test fails on Windows.
    tests/lsp/repro-compiler-test-slow.toit

    # Failing pipe on Windows:
    # https://github.com/toitlang/toit/issues/1369
    tests/lsp/import-completion-test.toit
  )
endif()
