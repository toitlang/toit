# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

# Checks that the C++ file from --native-source can be built by an external
# compiler. It only needs the libraries and the flags for linking from the SDK.

execute_process(
  COMMAND "${TOIT_COMPILE}" --project-root "${CMAKE_CURRENT_LIST_DIR}" --native-source -o "${WORK_DIR}/source-test.cc" "${SOURCE}"
  COMMAND_ERROR_IS_FATAL ANY
)

file(STRINGS "${WORK_DIR}/source-test.cc" INCLUDES REGEX "^#include")
if (NOT "${INCLUDES}" STREQUAL "#include <stdint.h>;#include <string.h>")
  message(FATAL_ERROR "Unexpected includes: ${INCLUDES}")
endif()

# The generated code is supposed to be clean. Only clang knows all the attributes.
# Compiler wrappers (like Nix's) may add linker flags that -fsyntax-only doesn't
# use, so don't let them fail the check.
if ("${CXX}" MATCHES "clang")
  execute_process(
    COMMAND "${CXX}" -std=gnu++11 -fsyntax-only -Wall -Wextra -Wpedantic -Werror
        -Wno-unused-command-line-argument
        "${WORK_DIR}/source-test.cc"
    COMMAND_ERROR_IS_FATAL ANY
  )
endif()

file(STRINGS "${NATIVE_SDK}/native.flags" FLAGS)
list(GET FLAGS 1 LINK_FLAGS)
string(REPLACE "@SDK@" "${NATIVE_SDK}" LINK_FLAGS "${LINK_FLAGS}")
separate_arguments(LINK_FLAGS)

execute_process(
  COMMAND "${CXX}" -std=gnu++11 -w -O1
      "${WORK_DIR}/source-test.cc" -o "${WORK_DIR}/source-test" ${LINK_FLAGS}
  COMMAND_ERROR_IS_FATAL ANY
)
execute_process(
  COMMAND "${WORK_DIR}/source-test"
  OUTPUT_VARIABLE OUTPUT
  COMMAND_ERROR_IS_FATAL ANY
)
if (NOT "${OUTPUT}" STREQUAL "hello from native code\n")
  message(FATAL_ERROR "Unexpected output: ${OUTPUT}")
endif()
