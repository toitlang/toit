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

if ("${CMAKE_SYSTEM_NAME}" STREQUAL "Windows" OR "${CMAKE_SYSTEM_NAME}" STREQUAL "MSYS")
  list(APPEND TOIT_FAILING_TESTS
    tests/toitp/bytecodes_toitp_test.toit
    tests/toitp/class_toitp_test.toit
    tests/toitp/dispatch_toitp_test.toit
    tests/toitp/literal_index_toitp_test.toit
    tests/toitp/literal_toitp_test.toit
    tests/toitp/method_toitp_test.toit
    tests/toitp/senders_toitp_test.toit
    tests/toitp/summary_toitp_test.toit
  )
endif()
