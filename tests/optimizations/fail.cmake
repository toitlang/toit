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
    tests/optimizations/byte_array_test.toit
    tests/optimizations/dead_code_test.toit
    tests/optimizations/eager_global_test.toit
    tests/optimizations/fold_test.toit
    tests/optimizations/lambda_test.toit
    tests/optimizations/return_test.toit
    tests/optimizations/tail_call_test.toit
    tests/optimizations/uninstantiated_classes_test.toit
    tests/optimizations/virtual_test.toit
  )
endif()
