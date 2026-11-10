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
  "tests/sandbox/field-access-test.toit"
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

# Programs run directly as untrusted containers with 'toit.run --untrusted'.
set(UNTRUSTED_RUN_TESTS
  # Name, program, expected exit code, expected output (regex).
  "print|print-main.toit|0|hello from the sandbox"
  # Long messages are truncated at a character boundary.
  "print-long|print-long-main.toit|0|é[.][.][.].*done printing"
  "denied|denied-main.toit|0|hostname: PERMISSION_DENIED.*file: PRIMITIVE_LOOKUP_FAILED"
  "uncaught|uncaught-main.toit|1|PERMISSION_DENIED"
  "deep-sleep|deep-sleep-main.toit|242|before deep sleep"
)

foreach(entry ${UNTRUSTED_RUN_TESTS})
  string(REPLACE "|" ";" fields "${entry}")
  list(GET fields 0 name)
  list(GET fields 1 program)
  list(GET fields 2 exit_code)
  list(GET fields 3 output)
  foreach(mode source snapshot)
    set(test_name "tests/sandbox/cli/${name}-${mode}")
    add_test(
      NAME ${test_name}
      COMMAND ${CMAKE_COMMAND}
          -DTOIT_RUN=$<TARGET_FILE:toit.run>
          -DPROGRAM=${CMAKE_CURRENT_SOURCE_DIR}/cli/${program}
          -DMODE=${mode}
          -DEXPECTED_EXIT=${exit_code}
          "-DEXPECTED_OUTPUT=${output}"
          -DTMP=${CMAKE_CURRENT_BINARY_DIR}/cli-${name}-${mode}
          -P ${CMAKE_CURRENT_SOURCE_DIR}/run-untrusted.cmake
      )
    set_tests_properties(${test_name} PROPERTIES TIMEOUT 40)
  endforeach()
endforeach()
