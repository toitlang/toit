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

set(NORMALIZE_GOLD ${TOIT_SDK_SOURCE_DIR}/tests/tools/normalize_gold.cmake)

add_custom_target(
  check_health
  COMMAND ${CMAKE_CTEST_COMMAND} -j${NUM_CPU} -T test -C health --output-on-failure -I ${TEST_SHARD_START},,${TEST_SHARD_STRIDE}
  USES_TERMINAL
  DEPENDS toit.compile
  )

add_custom_target(
  clear_health_gold
  COMMAND rm -f "${CMAKE_CURRENT_SOURCE_DIR}/*.gold"
)

add_custom_target(
  update_health_gold
)

set(NEGATIVE_PREFIX "${TOIT_SDK_SOURCE_DIR}/tests/negative/")
set(TPKG_PREFIX "${TOIT_SDK_SOURCE_DIR}/tools/tpkg/tests/")
set(GIT_PREFIX "${TOIT_SDK_SOURCE_DIR}/.git/")
# Normally not necessary as toit files in the build directory are generally
# only accessible through symlinks. But on Windows the globbing would find them.
set(BUILD_PREFIX "${CMAKE_SOURCE_DIR}/build/")

# Sets the RESULT variable to TRUE if STR has PREFIX as prefix.
# Leaves the RESULT variable untouched otherwise.
function(starts_with PREFIX STR RESULT)
  string(LENGTH "${PREFIX}" PREFIX_LEN)
  string(SUBSTRING "${STR}" 0 ${PREFIX_LEN} SUB)
  if ("${SUB}" STREQUAL "${PREFIX}")
    set(${RESULT} TRUE PARENT_SCOPE)
  endif()
endfunction()

foreach(file ${HEALTH_SOURCES})
  set(IS_PREFIXED FALSE)
  starts_with("${NEGATIVE_PREFIX}" "${file}" IS_PREFIXED)
  starts_with("${TPKG_PREFIX}" "${file}" IS_PREFIXED)
  starts_with("${GIT_PREFIX}" "${file}" IS_PREFIXED)
  starts_with("${BUILD_PREFIX}" "${file}" IS_PREFIXED)
  if (${IS_PREFIXED})
    continue()
  endif()
  get_filename_component(name ${file} NAME_WE)
  file(RELATIVE_PATH relative ${TOIT_SDK_SOURCE_DIR} ${file})
  string(REPLACE " " "__" TEST_NAME ${relative})
  string(REPLACE "/" "__" ESCAPED ${TEST_NAME})
  set(GOLD ${CMAKE_CURRENT_SOURCE_DIR}/${ESCAPED}.gold)
  # We don't use the path relative to the compiler, as analyzing `lib/...` would not be
  #   recognized as core library.
  set(LIB_PATH ".")

  add_test(
    NAME ${TEST_NAME}
    COMMAND ${CMAKE_COMMAND}
        -DTOITC=$<TARGET_FILE:toit.compile>
        "-DTEST=${relative}"
        "-DGOLD=${GOLD}"
        "-DLIB_DIR=${lib_dir}"
        "-DNORMALIZE_GOLD=${NORMALIZE_GOLD}"
        "-DTEST_ROOT=${TOIT_SDK_SOURCE_DIR}"
        "-DTMP=${CMAKE_BINARY_DIR}/tmp"
        "-DCMAKE_SYSTEM_NAME=${CMAKE_SYSTEM_NAME}"
        -P "${CMAKE_CURRENT_SOURCE_DIR}/run.cmake"
    WORKING_DIRECTORY ${TOIT_SDK_SOURCE_DIR}
    CONFIGURATIONS health
    )
  set_tests_properties(${TEST_NAME} PROPERTIES TIMEOUT 40)

  set(generate_gold build-health-${ESCAPED}.gold)
  add_custom_target(${generate_gold})

  add_custom_command(
    TARGET ${generate_gold}
    COMMAND ${CMAKE_COMMAND}
        -DUPDATE_GOLD=true
        -DTOITC=$<TARGET_FILE:toit.compile>
        "-DTEST=${relative}"
        "-DGOLD=${GOLD}"
        "-DLIB_DIR=${lib_dir}"
        "-DNORMALIZE_GOLD=${NORMALIZE_GOLD}"
        "-DTEST_ROOT=${TOIT_SDK_SOURCE_DIR}"
        "-DTMP=${CMAKE_BINARY_DIR}/tmp"
        "-DCMAKE_SYSTEM_NAME=${CMAKE_SYSTEM_NAME}"
        -P "${CMAKE_CURRENT_SOURCE_DIR}/run.cmake"
    WORKING_DIRECTORY ${TOIT_SDK_SOURCE_DIR}
    DEPENDS toit.compile
  )
  add_dependencies(update_health_gold ${generate_gold})
endforeach()

include(fail.cmake)
foreach(test ${TOIT_FAILING_TESTS})
  set_tests_properties(${test} PROPERTIES WILL_FAIL TRUE)
endforeach()
