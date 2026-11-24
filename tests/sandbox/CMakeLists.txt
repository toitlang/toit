# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by an MIT-style license that can be
# found in the lib/LICENSE file.

# Most sandbox tests are a trusted driver that starts an untrusted container
# (and a trusted sibling) from its own image. See sandbox.toit.
# The tests of the structural verifier and the interpreter hardening fork
# toit.run and toit.compile, so they take both as arguments.
set(TOOL_TESTS
  "tests/sandbox/field-access-test.toit"
  "tests/sandbox/runtime-hardening-test.toit"
  "tests/sandbox/verify-reject-test.toit"
  "tests/sandbox/verify-launch-test.toit"
  "tests/sandbox/install-verdict-test.toit"
  "tests/sandbox/invalid-utf-8-literal-test.toit"
)
file(GLOB SANDBOX_TESTS RELATIVE ${TOIT_SDK_SOURCE_DIR} "*-test.toit")

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
    set_tests_properties(${file} PROPERTIES TIMEOUT 120 ENVIRONMENT "TOIT_BYTECODE_FORMAT=2;TOIT_V2_UNCHECKED=0")
  else()
    add_test(
      NAME ${file}
      COMMAND $<TARGET_FILE:toit.run> ${file}
      WORKING_DIRECTORY ${TOIT_SDK_SOURCE_DIR}
      )
    set_tests_properties(${file} PROPERTIES TIMEOUT 40 ENVIRONMENT "TOIT_BYTECODE_FORMAT=2;TOIT_V2_UNCHECKED=0")
  endif()
endforeach()

# The sandbox tests start their untrusted containers from their own image,
# so the whole test is compiled in format 2 (TOIT_BYTECODE_FORMAT=2): the
# untrusted containers (and the trusted drivers) run on the verified core.
# The image must pass the untrusted rules, so it is compiled without the
# trusted-only opcodes (TOIT_V2_UNCHECKED=0) although the driver is trusted;
# the tool tests' child compilers inherit that. A program that is only run
# untrusted uses the user-facing switch instead (toit.run --untrusted, also
# for writing the snapshot: run-untrusted.cmake).
# Untrusted containers must be in format 2 unless -Xuntrusted_format1 or
# TOIT_UNTRUSTED_FORMAT1=1 is given (verified/core/DESIGN.md).

# Programs run directly as untrusted containers with 'toit.run --untrusted'.
set(UNTRUSTED_RUN_TESTS
  # Name, program, expected exit code, expected output (regex),
  # optionally output that must not appear (regex).
  "print|print-main.toit|0|hello from the sandbox"
  # Long messages are truncated at a character boundary.
  "print-long|print-long-main.toit|0|é[.][.][.].*done printing"
  "denied|denied-main.toit|0|hostname: PERMISSION_DENIED.*file: PRIMITIVE_LOOKUP_FAILED"
  # Large byte arrays work (external backing store, charged to the heap); the
  # explicit external and off-heap constructors are denied.
  "large-byte-array|large-byte-array-main.toit|0|100: size=100 zero=true last=42 filled=7.*10000: size=10000 zero=true last=42 filled=7.*1000000: size=1000000 zero=true last=42 filled=7.*buffer: hello.*external: PERMISSION_DENIED.*off-heap: PERMISSION_DENIED"
  "uncaught|uncaught-main.toit|1|PERMISSION_DENIED"
  # Finally records (unwinding without heap tokens) across calls, stack
  # growth, GC and task switches.
  "finally-records|finally-records-main.toit|0|0: 2000 boom.*2: 2000 boom.*r=1 \\[inner\\].*loop=100000.*finally records done"
  # The verifier rejects deep sleep in untrusted programs at launch; the
  # program never runs.
  "deep-sleep|deep-sleep-main.toit|1|HALT 2.*VERIFICATION_FAILED|before deep sleep"
  # A weak map's unreachable value is replaced by null by an old-space
  # collection (the collector writes into a reachable object).
  "weak-map|weak-map-main.toit|0|key=null kept=present 7"
)

foreach(entry ${UNTRUSTED_RUN_TESTS})
  string(REPLACE "|" ";" fields "${entry}")
  list(GET fields 0 name)
  list(GET fields 1 program)
  list(GET fields 2 exit_code)
  list(GET fields 3 output)
  set(unexpected "")
  list(LENGTH fields field_count)
  if(field_count GREATER 4)
    list(GET fields 4 unexpected)
  endif()
  foreach(mode source snapshot)
    set(test_name "tests/sandbox/cli/${name}-${mode}")
    add_test(
      NAME ${test_name}
      COMMAND ${CMAKE_COMMAND}
          -DTOIT_RUN=$<TARGET_FILE:toit.run>
          -DPROGRAM=${CMAKE_CURRENT_SOURCE_DIR}/cli/${program}
          -DMODE=${mode}
          -DCOMPILE_FLAGS=--untrusted
          -DEXPECTED_EXIT=${exit_code}
          "-DEXPECTED_OUTPUT=${output}"
          "-DUNEXPECTED_OUTPUT=${unexpected}"
          -DTMP=${CMAKE_CURRENT_BINARY_DIR}/cli-${name}-${mode}
          -P ${CMAKE_CURRENT_SOURCE_DIR}/run-untrusted.cmake
      )
    set_tests_properties(${test_name} PROPERTIES TIMEOUT 40 ENVIRONMENT "TOIT_BYTECODE_FORMAT=2")
  endforeach()
endforeach()

# FORMAT-1-ONLY (docs/format2-migration.md): delete with format 1.
# A format-1 snapshot is refused as an untrusted container by default, and
# runs (on the C++ interpreter) when format 1 is allowed.
foreach(variant refused allowed)
  if(variant STREQUAL "refused")
    set(env "TOIT_BYTECODE_FORMAT=1")
    set(exit_code 1)
    set(output "FORMAT_2_REQUIRED")
    set(unexpected "hello from the sandbox")
  else()
    set(env "TOIT_BYTECODE_FORMAT=1;TOIT_UNTRUSTED_FORMAT1=1")
    set(exit_code 0)
    set(output "hello from the sandbox")
    set(unexpected "")
  endif()
  set(test_name "tests/sandbox/cli/format1-${variant}-snapshot")
  add_test(
    NAME ${test_name}
    COMMAND ${CMAKE_COMMAND}
        -DTOIT_RUN=$<TARGET_FILE:toit.run>
        -DPROGRAM=${CMAKE_CURRENT_SOURCE_DIR}/cli/print-main.toit
        -DMODE=snapshot
        -DEXPECTED_EXIT=${exit_code}
        "-DEXPECTED_OUTPUT=${output}"
        "-DUNEXPECTED_OUTPUT=${unexpected}"
        -DTMP=${CMAKE_CURRENT_BINARY_DIR}/cli-format1-${variant}
        -P ${CMAKE_CURRENT_SOURCE_DIR}/run-untrusted.cmake
    )
  set_tests_properties(${test_name} PROPERTIES TIMEOUT 40 ENVIRONMENT "${env}")
endforeach()
