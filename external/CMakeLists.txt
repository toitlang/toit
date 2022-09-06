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

set(TOIT_EXTERNAL_SCRIPT "${CMAKE_CURRENT_LIST_DIR}/CMakeLists.txt")

set(TOIT_REPOS
    https://github.com/kasperl/toit-qubitro
    https://github.com/nilwes/LIS3DH
    https://github.com/toitlang/jaguar
    https://github.com/toitlang/pkg-ar
    https://github.com/toitlang/pkg-host
    https://github.com/toitlang/pkg-http
    https://github.com/toitlang/pkg-modbus
    https://github.com/toitlang/pkg-ntp
    https://github.com/toitlang/pkg-tar
    https://github.com/toitlang/pkg-testing
    https://github.com/toitware/bme280-driver
    # https://github.com/toitware/cellular
    https://github.com/toitware/dbc
    https://github.com/toitware/icm20948-driver
    https://github.com/toitware/max31865-driver
    https://github.com/toitware/mcp2518fd-driver
    https://github.com/toitware/mcp342x-driver
    https://github.com/toitware/mqtt
    # https://github.com/toitware/quectel-cellular
    # https://github.com/toitware/sequans-cellular
    https://github.com/toitware/sts3x-driver
    https://github.com/toitware/toit-A3967
    https://github.com/toitware/toit-axp192
    https://github.com/toitware/toit-cert-roots
    https://github.com/toitware/toit-color-tft
    https://github.com/toitware/toit-e-paper
    https://github.com/toitware/toit-font-clock
    https://github.com/toitware/toit-font-google-100dpi-roboto
    https://github.com/toitware/toit-gnss-location
    https://github.com/toitware/toit-heading
    https://github.com/toitware/toit-hx711
    https://github.com/toitware/toit-icons-pictogrammers
    https://github.com/toitware/toit-location
    https://github.com/toitware/toit-lsm303d
    https://github.com/toitware/toit-lsm303dlh
    https://github.com/toitware/toit-lsm303dlhc
    https://github.com/toitware/toit-m5stack-core2
    https://github.com/toitware/toit-morse
    https://github.com/toitware/toit-morse-tutorial
    https://github.com/toitware/toit-msa311
    https://github.com/toitware/toit-newton-raphson
    https://github.com/toitware/toit-pixel-display
    https://github.com/toitware/toit-pixel-strip
    https://github.com/toitware/toit-png-display
    https://github.com/toitware/toit-r46ca01
    https://github.com/toitware/toit-resistance-to-temperature
    https://github.com/toitware/toit-rs485
    https://github.com/toitware/toit-si7006
    https://github.com/toitware/toit-solar-position
    https://github.com/toitware/toit-ssd1306
    https://github.com/toitware/toit-tl19a08
    https://github.com/toitware/toit-tm1640
    https://github.com/toitware/toit-vcnl4040
    # https://github.com/toitware/ublox-cellular
    https://github.com/toitware/ublox-gnss-driver
)

set(DOWNLOADS_DIR "${CMAKE_CURRENT_LIST_DIR}/downloads")

# This file serves as CMakeLists.txt, as well as a cmake-script, run with `cmake -P`.
# In the latter case the `EXECUTING_SCRIPT` variable is defined, and we only
# process the command that we should execute.
if (DEFINED EXECUTING_SCRIPT)
  if ("${SCRIPT_COMMAND}" STREQUAL "download")
    find_package(Git REQUIRED)
    file(MAKE_DIRECTORY "${DOWNLOADS_DIR}")
    message("Downloading ${REPO}")
    get_filename_component(REPO_NAME "${REPO}" NAME)
    set(REPO_PATH "${DOWNLOADS_DIR}/${REPO_NAME}")
    if (EXISTS "${REPO_PATH}")
      execute_process(
        COMMAND "${GIT_EXECUTABLE}" pull
        WORKING_DIRECTORY "${REPO_PATH}"
        COMMAND_ERROR_IS_FATAL ANY
      )
    else()
      execute_process(
        COMMAND "${GIT_EXECUTABLE}" clone --depth 1 "${REPO}"
        WORKING_DIRECTORY "${DOWNLOADS_DIR}"
        COMMAND_ERROR_IS_FATAL ANY
      )
    endif()
  else()
    message(FATAL_ERROR "Unknown script command ${SCRIPT_COMMAND}")
  endif()

  # End the execution of this file.
  return()
endif()

option(TOIT_TEST_EXTERNAL "Download and test external toit repositories" OFF)

if (NOT ${TOIT_TEST_EXTERNAL})
  return()
endif()

# The SHARD_START end SHARD_STRIDE environment variables must be set when
# generating the cmake files.
# I couldn't figure out how to use them while running the tests.
set(TEST_SHARD_START "$ENV{SHARD_START}")
set(TEST_SHARD_STRIDE "$ENV{SHARD_STRIDE}")

set(EXTERNAL_GOLD_DIR "${CMAKE_CURRENT_LIST_DIR}/gold")

add_custom_target(
  check_external
  COMMAND ${CMAKE_CTEST_COMMAND} -j${NUM_CPU} -T test -C external --output-on-failure -I ${TEST_SHARD_START},,${TEST_SHARD_STRIDE}
  USES_TERMINAL
  )

add_custom_target(
  check_external_health
  COMMAND "${CMAKE_CTEST_COMMAND}" -j${NUM_CPU} -T test -C external_health --output-on-failure -I ${TEST_SHARD_START},,${TEST_SHARD_STRIDE}
  USES_TERMINAL
  )

add_custom_target(
  clear_external_health_gold
  COMMAND rm -f "${EXTERNAL_GOLD_DIR}/*.gold"
)

add_custom_target(
  # Dependencies will be added by the add_health_test.
  update_external_health_gold
)

add_custom_target(
  # Dependencies are added below.
  download_external
)
foreach(REPO ${TOIT_REPOS})
  get_filename_component(REPO_NAME "${REPO}" NAME)
  set(TARGET_NAME "download_external-${REPO_NAME}")
  add_custom_target(
    "${TARGET_NAME}"
    # We call this same script again, but with variables such that it downloads
    # all repositories.
    COMMAND "${CMAKE_COMMAND}"
        -DREPO="${REPO}"
        -DEXECUTING_SCRIPT=true
        -DSCRIPT_COMMAND=download
        -P "${TOIT_EXTERNAL_SCRIPT}"
  )
  add_dependencies(download_external "${TARGET_NAME}")
endforeach()

# Finds projects (folders with package.lock/yaml files) in the given repo.
function(find_toit_projects REPO)
  get_filename_component(REPO_NAME "${REPO}" NAME)
  set(REPO_PATH "${DOWNLOADS_DIR}/${REPO_NAME}")
  foreach(LOCATION "" "examples" "tests")
    set(LOCATION_PATH "${REPO_PATH}/${LOCATION}")
    if (EXISTS "${LOCATION_PATH}/package.yaml" OR EXISTS "${LOCATION_PATH}/package.lock")
      set(PROJECT_NAME "${REPO_NAME}")
      if (NOT "${LOCATION}" STREQUAL "")
        set(PROJECT_NAME "${PROJECT_NAME}-${LOCATION}")
      endif()
      # Mark it as a toit-project so we download its dependencies.
      toit_project("${PROJECT_NAME}" "${LOCATION_PATH}")
    endif()
  endforeach()
endfunction()

function(add_repo_tests REPO)
  get_filename_component(REPO_NAME "${REPO}" NAME)
  set(REPO_PATH "${DOWNLOADS_DIR}/${REPO_NAME}")
  file(GLOB TEST_FILES RELATIVE "${CMAKE_SOURCE_DIR}"
      "${REPO_PATH}/tests/*_test.toit"
      "${REPO_PATH}/tests/*_test_slow.toit")

  file(RELATIVE_PATH TEST_PREFIX "${CMAKE_SOURCE_DIR}" "${REPO_PATH}")
  set(FAILING_TESTS)
  set(SKIP_TESTS)
  include("${REPO_PATH}/test/fail.cmake" OPTIONAL)
  include("${REPO_PATH}/tests/fail.cmake" OPTIONAL)

  foreach(FILE ${TEST_FILES})
    if("${FILE}" IN_LIST SKIP_TESTS)
      continue()
    endif()
    add_test(
      NAME "${FILE}"
      COMMAND $<TARGET_FILE:toit.run> "${FILE}"
      WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}"
      CONFIGURATIONS external
    )
    if("${FILE}" IN_LIST FAILING_TESTS)
      set_tests_properties(${FILE} PROPERTIES WILL_FAIL TRUE)
    endif()
  endforeach()
endfunction()

foreach(REPO ${TOIT_REPOS})
  find_toit_projects("${REPO}")
  add_repo_tests("${REPO}")
endforeach()

include("${TOIT_SDK_SOURCE_DIR}/tests/tools/health.cmake")

file(GLOB_RECURSE HEALTH_SOURCES "${CMAKE_CURRENT_LIST_DIR}/*.toit")

foreach(FILE ${HEALTH_SOURCES})
  if (FILE MATCHES "/[.]packages/")
    continue()
  endif()

  add_health_test("${FILE}"
    RELATIVE_TO "${DOWNLOADS_DIR}"
    LIB_DIR "${TOIT_SDK_SOURCE_DIR}"
    GOLD_DIR "${EXTERNAL_GOLD_DIR}"
    CONFIGURATION external_health
    UPDATE_TARGET update_external_health_gold
  )
endforeach()
