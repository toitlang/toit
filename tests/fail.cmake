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

if ("${CMAKE_SIZEOF_VOID_P}" EQUAL 4)
  # For tests that crash (instead of failing). Ctest doesn't have a way to deal
  # with that, so we skip the test.
  # See https://gitlab.kitware.com/cmake/cmake/-/issues/20397
  set(TOIT_SKIP_TESTS
  )
endif()

list(APPEND TOIT_SKIP_TESTS
)

list(APPEND TOIT_FLAKY_TESTS
  tests/tls-client-cert-test.toit
  tests/tls-global-cert-test-slow.toit
  tests/tls-test-slow.toit
)

if ("${CMAKE_SYSTEM_NAME}" STREQUAL "Windows" OR "${CMAKE_SYSTEM_NAME}" STREQUAL "MSYS")
  list(APPEND TOIT_FAILING_TESTS
    tests/time-test.toit # https://github.com/toitlang/toit/issues/1369
    tests/zlib-test.toit
    tests/cow-read-only-test-compiler.toit
    tests/uart-test.toit
  )
endif()

if ("${CMAKE_SYSTEM_NAME}" STREQUAL "Darwin")
  list(APPEND TOIT_FAILING_TESTS
    tests/uart-test.toit
  )
endif()
