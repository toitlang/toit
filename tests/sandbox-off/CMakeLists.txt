# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by an MIT-style license that can be
# found in the lib/LICENSE file.

# The tests of a VM built without sandboxes (CMake TOIT_SANDBOX=OFF; the
# sandbox tests in tests/sandbox need them). verified/check.sh section
# `sandbox-off` builds such a VM and runs them.
set(SANDBOX_OFF_TESTS
  "tests/sandbox-off/refused-test.toit"
)

foreach(file ${SANDBOX_OFF_TESTS})
  if("${file}" IN_LIST TOIT_SKIP_TESTS)
    continue()
  endif()
  add_test(
    NAME ${file}
    COMMAND $<TARGET_FILE:toit.run> ${file} $<TARGET_FILE:toit.run> $<TARGET_FILE:toit.compile>
    WORKING_DIRECTORY ${TOIT_SDK_SOURCE_DIR}
    )
  set_tests_properties(${file} PROPERTIES TIMEOUT 120 ENVIRONMENT "TOIT_BYTECODE_FORMAT=2")
endforeach()
