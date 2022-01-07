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

if ("${CMAKE_SYSTEM_NAME}" STREQUAL "Windows")
  list(APPEND TOIT_FAILING_TESTS
    tests/negative/import9_test.toit
    tests/negative/importA_test.toit
    tests/negative/importB_test.toit
    tests/negative/importC_test.toit
    tests/negative/importD_test.toit
    tests/negative/import_no_exit_test.toit
    tests/negative/is_test.toit
    tests/negative/lock_sdk_bad/lock_sdk_bad_test.toit
    tests/negative/lock_sdk_bad2/lock_sdk_bad_test.toit
    tests/negative/lock_sdk_empty/lock_sdk_empty_test.toit
    tests/negative/pkg_bad_path/main_test.toit
    tests/negative/pkg_dot_out/main_test.toit
    tests/negative/pkg_lock_errors/main_test.toit
    tests/negative/pkg_no_src/main_test.toit
    tests/negative/pkg_not_found/main_test.toit
    tests/negative/pkg_not_found/relative_test.toit
    tests/negative/pkg_not_found_error/main_test.toit
    tests/negative/pkg_rel_not_found/main_test.toit
  )
endif()
