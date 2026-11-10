# Copyright (C) 2026 Toit contributors.
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

# Most sandbox tests are a trusted driver that starts an untrusted container
# (and a trusted sibling) from its own image. See sandbox.toit.
# The tests of the interpreter hardening fork toit.run and toit.compile, so
# they take both as arguments.
set(TOOL_TESTS
  "tests/sandbox/runtime-hardening-test.toit"
)
file(GLOB SANDBOX_TESTS RELATIVE "${TOIT_SDK_SOURCE_DIR}" "*-test.toit")

foreach(file ${SANDBOX_TESTS})
  if("${file}" IN_LIST TOIT_SKIP_TESTS)
    continue()
  endif()
  if("${file}" IN_LIST TOOL_TESTS)
    add_test(
      NAME ${file}
      COMMAND $<TARGET_FILE:toit.run> ${file} $<TARGET_FILE:toit.run> $<TARGET_FILE:toit.compile>
      WORKING_DIRECTORY ${TOIT_SDK_SOURCE_DIR}
      )
    set_tests_properties(${file} PROPERTIES TIMEOUT 120)
  else()
    add_test(
      NAME ${file}
      COMMAND $<TARGET_FILE:toit.run> ${file}
      WORKING_DIRECTORY ${TOIT_SDK_SOURCE_DIR}
      )
    set_tests_properties(${file} PROPERTIES TIMEOUT 40)
  endif()
endforeach()
