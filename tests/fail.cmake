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
  # The test crashes (instead of failing). Ctest doesn't have a way to deal with that.
  # See https://gitlab.kitware.com/cmake/cmake/-/issues/20397
  # For now simply skip it.
  set(TOIT_SKIP_TESTS
    # Note: the test shouldn't crash. In the internal version the test succeeds.
    tests/max_heap_size_test.toit
  )
endif()

set(TOIT_FAILING_TESTS
)

if ("${CMAKE_SYSTEM_NAME}" STREQUAL "Windows" OR "${CMAKE_SYSTEM_NAME}" STREQUAL "MSYS")
  list(APPEND TOIT_FAILING_TESTS
    tests/ar_test.toit
    tests/close_test.toit
    tests/dns_test.toit
    tests/file_test.toit
    tests/interface_address_test.toit
    tests/keepalive_test.toit
    tests/pipe2_test.toit
    tests/pipe_test.toit
    tests/regress/issue3_test.toit
    tests/socket_close_test.toit
    tests/socket_option_test.toit
    tests/socket_task_test.toit
    tests/socket_test.toit
    tests/socket_timeout_test.toit
    tests/tar_test.toit
    tests/time_test.toit
    tests/tls2_test.toit
    tests/udp_test.toit
    tests/zlib_test.toit
    tests/class_field_limit_test_compiler.toit
    tests/cow_read_only_test_compiler.toit
    tests/fork_stress_test_slow.toit
    tests/tls_test_slow.toit
  )
endif()
