# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by an MIT-style license that can be
# found in the lib/LICENSE file.

# Most sandbox tests are a trusted driver that starts an untrusted container
# (and a trusted sibling) from its own image. See sandbox.toit.
# The tests of the structural verifier and the interpreter hardening fork
# toit.run and toit.compile, so they take both as arguments.
set(TOOL_TESTS
  "tests/sandbox/runtime-hardening-test.toit"
  "tests/sandbox/verify-reject-test.toit"
  "tests/sandbox/verify-launch-test.toit"
  "tests/sandbox/install-verdict-test.toit"
  "tests/sandbox/boot-refused-test.toit"
  "tests/sandbox/verdict-epoch-test.toit"
  "tests/sandbox/invalid-utf-8-literal-test.toit"
  "tests/sandbox/heap-floor-test.toit"
  "tests/sandbox/oom-report-rate-test.toit"
  "tests/sandbox/system-oom-request-test.toit"
  "tests/sandbox/sandbox-start-floor-test.toit"
  "tests/sandbox/reply-to-full-sandbox-test.toit"
  "tests/sandbox/system-oom-relief-test.toit"
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

# The sandbox network services (experimental, docs/sandbox-policy.md,
# "Network access"). The tests are their own project (they use the http
# package and start the provider container from their own image).
file(GLOB SANDBOX_NET_TESTS RELATIVE ${TOIT_SDK_SOURCE_DIR} "net/*-test.toit")
foreach(file ${SANDBOX_NET_TESTS})
  if("${file}" IN_LIST TOIT_SKIP_TESTS)
    continue()
  endif()
  add_test(
    NAME ${file}
    COMMAND $<TARGET_FILE:toit.run> ${file}
    WORKING_DIRECTORY ${TOIT_SDK_SOURCE_DIR}
    )
  set_tests_properties(${file} PROPERTIES TIMEOUT 90 ENVIRONMENT
      "TOIT_BYTECODE_FORMAT=2;TOIT_V2_UNCHECKED=0")
endforeach()

# The sandbox tests start their untrusted containers from their own image,
# so the whole test is compiled in format 2 (TOIT_BYTECODE_FORMAT=2): the
# untrusted containers (and the trusted drivers) run on the verified core.
# The image must pass the untrusted rules, so it is compiled without the
# trusted-only opcodes (TOIT_V2_UNCHECKED=0) although the driver is trusted;
# the tool tests' child compilers inherit that. A program that is only run
# untrusted uses the user-facing switch instead (toit.run --untrusted, also
# for writing the snapshot: run-untrusted.cmake).
# Untrusted containers must be in format 2 (verified/core/DESIGN.md).

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
  # ByteOrder.put-uint with 9 bytes writes the same bytes in either order,
  # through the Rust port (a fresh byte array) and the C++ (a literal).
  "byte-order-width|byte-order-width-main.toit|0|big: \\[0, 255, 255, 255, 255, 255, 255, 255, 255\\] \\[0, 255, 255, 255, 255, 255, 255, 255, 255\\].*little: \\[255, 255, 255, 255, 255, 255, 255, 255, 0\\] \\[255, 255, 255, 255, 255, 255, 255, 255, 0\\].*eight: \\[1, 2, 3, 4, 5, 6, 7, 8\\]"
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

# A program whose own library lets a string slice cut a character makes a
# string that is not valid UTF-8; string_at reads only inside it (wave 10).
add_test(
  NAME tests/sandbox/cli/cut-slice-snapshot
  COMMAND ${CMAKE_COMMAND}
      -DTOIT_RUN=$<TARGET_FILE:toit.run>
      -DPROGRAM=${CMAKE_CURRENT_SOURCE_DIR}/cli/cut-slice-main.toit
      "-DEXPECTED_OUTPUT=size=7 at=null.*size=14 at=null"
      -DTMP=${CMAKE_CURRENT_BINARY_DIR}/cli-cut-slice
      -P ${CMAKE_CURRENT_SOURCE_DIR}/run-cut-slice.cmake
  )
set_tests_properties(tests/sandbox/cli/cut-slice-snapshot PROPERTIES TIMEOUT 60 ENVIRONMENT "TOIT_BYTECODE_FORMAT=2")

# Strings that are not valid UTF-8, made the same way, given to the
# primitives and the message encoder (the run-time half of
# invalid-utf-8-literal-test.toit).
add_test(
  NAME tests/sandbox/cli/invalid-strings-snapshot
  COMMAND ${CMAKE_COMMAND}
      -DTOIT_RUN=$<TARGET_FILE:toit.run>
      -DPROGRAM=${CMAKE_CURRENT_SOURCE_DIR}/cli/invalid-strings-main.toit
      "-DEXPECTED_OUTPUT=utf-16 units: 7 last: fffd.*encoded: [0-9]+.*encode-object: PERMISSION_DENIED.*send to system: WRONG_OBJECT_TYPE.*send nested: WRONG_OBJECT_TYPE.*done"
      -DTMP=${CMAKE_CURRENT_BINARY_DIR}/cli-invalid-strings
      -P ${CMAKE_CURRENT_SOURCE_DIR}/run-cut-slice.cmake
  )
set_tests_properties(tests/sandbox/cli/invalid-strings-snapshot PROPERTIES TIMEOUT 60 ENVIRONMENT "TOIT_BYTECODE_FORMAT=2")

# FORMAT-1-ONLY (docs/format2-migration.md): delete with format 1.
# A format-1 snapshot is refused as an untrusted container in every build:
# untrusted programs never run on the C++ interpreter. The flag and the
# variable that used to allow it (-Xuntrusted_format1,
# TOIT_UNTRUSTED_FORMAT1=1) no longer exist and change nothing.
foreach(variant refused old-variable old-flag)
  set(env "TOIT_BYTECODE_FORMAT=1")
  set(run_flags "")
  if(variant STREQUAL "old-variable")
    set(env "TOIT_BYTECODE_FORMAT=1;TOIT_UNTRUSTED_FORMAT1=1")
  elseif(variant STREQUAL "old-flag")
    set(run_flags "-Xuntrusted_format1")
  endif()
  set(test_name "tests/sandbox/cli/format1-${variant}-snapshot")
  add_test(
    NAME ${test_name}
    COMMAND ${CMAKE_COMMAND}
        -DTOIT_RUN=$<TARGET_FILE:toit.run>
        -DPROGRAM=${CMAKE_CURRENT_SOURCE_DIR}/cli/print-main.toit
        -DMODE=snapshot
        -DRUN_FLAGS=${run_flags}
        -DEXPECTED_EXIT=1
        "-DEXPECTED_OUTPUT=FORMAT_2_REQUIRED"
        "-DUNEXPECTED_OUTPUT=hello from the sandbox"
        -DTMP=${CMAKE_CURRENT_BINARY_DIR}/cli-format1-${variant}
        -P ${CMAKE_CURRENT_SOURCE_DIR}/run-untrusted.cmake
    )
  set_tests_properties(${test_name} PROPERTIES TIMEOUT 40 ENVIRONMENT "${env}")
endforeach()

# The verification epoch (verified/verification-epoch.cmake): the build's
# epoch is the one of the sources, and the gate that records it fails when
# an input of the install-time checks changes (its self-test).
add_test(
  NAME tests/sandbox/verification-epoch-gate
  COMMAND ${CMAKE_COMMAND}
      -DWORK=${CMAKE_CURRENT_BINARY_DIR}/verification-epoch-self-test
      -DEXPECTED_EPOCH=${TOIT_VERIFICATION_EPOCH}
      -P ${TOIT_SDK_SOURCE_DIR}/verified/tools/verification-epoch-self-test.cmake
  )
set_tests_properties(tests/sandbox/verification-epoch-gate PROPERTIES TIMEOUT 60)
