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

file(GLOB_RECURSE HEALTH_SOURCES "${TOIT_SDK_SOURCE_DIR}/*.toit")

include("${TOIT_SDK_SOURCE_DIR}/tests/tools/health.cmake")

set(GOLD_DIR "${CMAKE_CURRENT_SOURCE_DIR}/gold/sdk")

add_custom_target(
  check_health
  COMMAND ${CMAKE_CTEST_COMMAND} -j${NUM_CPU} -T test -C health --output-on-failure -I ${TEST_SHARD_START},,${TEST_SHARD_STRIDE}
  USES_TERMINAL
  DEPENDS toit.compile
  )

add_custom_target(
  clear_health_gold
  COMMAND rm -f "${GOLD_DIR}/*.gold"
)

add_custom_target(
  update_health_gold
)

set(SKIP_PREFIXES
    "${TOIT_SDK_SOURCE_DIR}/tests/negative/"
    "${TOIT_SDK_SOURCE_DIR}/tools/tpkg/tests/"
    "${TOIT_SDK_SOURCE_DIR}/.git/"
    # Don't go into the packages directory which only contains external packages.
    "${TOIT_SDK_SOURCE_DIR}/packages/"
    # Normally not necessary as toit files in the build directory are generally
    # only accessible through symlinks. But on Windows the globbing would find them.
    "${CMAKE_SOURCE_DIR}/build/")

# Don't go into .packages directories.
# The packages we want to check must be added differently.
set(DOT_PACKAGES_PATTERN "/[.]packages/")

# Sets the RESULT variable to TRUE if STR has PREFIX as prefix.
# Leaves the RESULT variable untouched otherwise.
function(starts_with PREFIX STR RESULT)
  string(LENGTH "${PREFIX}" PREFIX_LEN)
  string(SUBSTRING "${STR}" 0 ${PREFIX_LEN} SUB)
  if ("${SUB}" STREQUAL "${PREFIX}")
    set(${RESULT} TRUE PARENT_SCOPE)
  endif()
endfunction()

function(contains PATTERN STR RESULT)
  string(REGEX MATCH "${PATTERN}" FOUND_MATCH "${STR}")
  if (NOT "${FOUND_MATCH}" STREQUAL "")
    set(${RESULT} TRUE PARENT_SCOPE)
  endif()
endfunction()

foreach(file ${HEALTH_SOURCES})
  set(SHOULD_SKIP FALSE)
  foreach(PREFIX ${SKIP_PREFIXES})
    starts_with("${PREFIX}" "${file}" SHOULD_SKIP)
  endforeach()
  contains("${DOT_PACKAGES_PATTERN}" "${file}" SHOULD_SKIP)
  if (${SHOULD_SKIP})
    continue()
  endif()
  add_health_test("${file}"
    RELATIVE_TO "${TOIT_SDK_SOURCE_DIR}"
    LIB_DIR "${TOIT_SDK_SOURCE_DIR}"
    GOLD_DIR "${GOLD_DIR}"
    CONFIGURATION health
    UPDATE_TARGET update_health_gold
  )
endforeach()

include(fail.cmake)
foreach(test ${TOIT_FAILING_TESTS})
  set_tests_properties(${test} PROPERTIES WILL_FAIL TRUE)
endforeach()
