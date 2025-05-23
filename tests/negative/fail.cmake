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

set(TOIT_FAILING_TESTS
)

list(APPEND TOIT_OPTIMIZATION_SKIP_TESTS
  # The following tests only work with standard optimizations.
  tests/negative/field-type5-test.toit
)

# The following test is only relevant on Windows and macOS.
if("${CMAKE_SYSTEM_NAME}" STREQUAL "Linux")
  list(APPEND TOIT_SKIP_TESTS
    tests/negative/bad-case-import-test.toit
  )
endif()
