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
    https://github.com/floitsch/toit-telegram
    https://github.com/floitsch/toit-discord
    https://github.com/floitsch/toit-device-bot
    https://github.com/kasperl/toit-datacake
    https://github.com/kasperl/toit-qubitro
    https://github.com/kasperl/toit-zygote
    https://github.com/lask/toit-hc-sr04
    https://github.com/nilwes/bno055
    https://github.com/nilwes/HD44780
    https://github.com/nilwes/LIS3DH
    https://github.com/toitlang/jaguar
    https://github.com/toitlang/pkg-ar
    https://github.com/toitlang/pkg-dns-simple-server
    https://github.com/toitlang/pkg-font-tiny
    https://github.com/toitlang/pkg-host
    https://github.com/toitlang/pkg-http
    https://github.com/toitlang/pkg-modbus
    https://github.com/toitlang/pkg-ntp
    https://github.com/toitlang/pkg-tar
    https://github.com/toitlang/pkg-testing
    https://github.com/toitlang/toit-font-tools
    https://github.com/toitware/bme280-driver
    https://github.com/toitware/cellular
    https://github.com/toitware/dbc
    https://github.com/toitware/demo-encrypted-ota
    https://github.com/toitware/icm20948-driver
    https://github.com/toitware/max31865-driver
    https://github.com/toitware/mcp2518fd-driver
    https://github.com/toitware/mcp342x-driver
    https://github.com/toitware/mqtt
    https://github.com/toitware/sts3x-driver
    https://github.com/toitware/toit-A3967
    https://github.com/toitware/toit-artemis
    https://github.com/toitware/toit-axp192
    https://github.com/toitware/toit-cert-roots
    https://github.com/toitware/toit-color-tft
    https://github.com/toitware/toit-ds18b20
    https://github.com/toitware/toit-e-paper
    https://github.com/toitware/toit-font-clock
    https://github.com/toitware/toit-font-google-100dpi-roboto
    https://github.com/toitware/toit-gnss-location
    https://github.com/toitware/toit-heading
    https://github.com/toitware/toit-hx711
    https://github.com/toitware/toit-ibutton
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
    https://github.com/toitware/toit-openai
    https://github.com/toitware/toit-partition-table-esp32
    https://github.com/toitware/toit-pixel-display
    https://github.com/toitware/toit-pixel-strip
    https://github.com/toitware/toit-png-display
    https://github.com/toitware/toit-png-tools
    https://github.com/toitware/toit-protobuf
    https://github.com/toitware/toit-provision
    https://github.com/toitware/toit-qwiic-joystick
    https://github.com/toitware/toit-r46ca01
    https://github.com/toitware/toit-resistance-to-temperature
    https://github.com/toitware/toit-rs485
    https://github.com/toitware/toit-si7006
    https://github.com/toitware/toit-solar-position
    https://github.com/toitware/toit-ssd1306
    https://github.com/toitware/toit-semver
    https://github.com/toitware/toit-supabase
    https://github.com/toitware/toit-tl19a08
    https://github.com/toitware/toit-tm1640
    https://github.com/toitware/toit-vcnl4040
    https://github.com/toitware/toit-watchdog
    https://github.com/toitware/toit-1-wire
    https://github.com/toitware/ublox-gnss-driver
    https://github.com/toitware/ubx-message
)

set(DOWNLOADS_DIR "${CMAKE_CURRENT_LIST_DIR}/downloads")

include(ProcessorCount)
ProcessorCount(NUM_CPU)

IF(APPLE)
  set(DEFAULT_TIMEOUT 80)
  set(SLOW_TIMEOUT 800)
else()
  set(DEFAULT_TIMEOUT 40)
  set(SLOW_TIMEOUT 400)
endif()

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
        COMMAND "${GIT_EXECUTABLE}" reset --hard
        WORKING_DIRECTORY "${REPO_PATH}"
        COMMAND_ERROR_IS_FATAL ANY
      )
      execute_process(
        COMMAND "${GIT_EXECUTABLE}" clean -fd
        WORKING_DIRECTORY "${REPO_PATH}"
        COMMAND_ERROR_IS_FATAL ANY
      )
      execute_process(
        COMMAND "${GIT_EXECUTABLE}" pull
        WORKING_DIRECTORY "${REPO_PATH}"
        COMMAND_ERROR_IS_FATAL ANY
      )
      execute_process(
        COMMAND "${GIT_EXECUTABLE}" submodule update --init --recursive
        WORKING_DIRECTORY "${REPO_PATH}"
        COMMAND_ERROR_IS_FATAL ANY
      )
    else()
      execute_process(
        COMMAND "${GIT_EXECUTABLE}" clone --depth 1 "${REPO}"
        WORKING_DIRECTORY "${DOWNLOADS_DIR}"
        COMMAND_ERROR_IS_FATAL ANY
      )
      message("Downloading submodules for ${REPO}")
      execute_process(
        COMMAND "${GIT_EXECUTABLE}" submodule update --init --recursive
        WORKING_DIRECTORY "${REPO_PATH}"
        COMMAND_ERROR_IS_FATAL ANY
      )
    endif()
    # If bin/version.toit.in (or app/version.toit.in) exists, copy it to
    # bin/version.toit (resp. app/version.toit).
    foreach(LOCATION "app" "bin")
      set(LOCATION_PATH "${REPO_PATH}/${LOCATION}")
      if (EXISTS "${LOCATION_PATH}/version.toit.in")
        configure_file("${LOCATION_PATH}/version.toit.in" "${LOCATION_PATH}/version.toit" COPYONLY)
      endif()
    endforeach()
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
  foreach(LOCATION "" "examples" "tests" "tools" "app" "bin")
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

include(fail.cmake OPTIONAL)

function(add_repo_tests REPO)
  get_filename_component(REPO_NAME "${REPO}" NAME)
  set(REPO_PATH "${DOWNLOADS_DIR}/${REPO_NAME}")
  file(GLOB TEST_FILES RELATIVE "${REPO_PATH}"
      "${REPO_PATH}/tests/*-test.toit"
      "${REPO_PATH}/tests/*_test.toit"
      "${REPO_PATH}/tests/*-test-slow.toit"
      "${REPO_PATH}/tests/*_test_slow.toit")

  # Set the TEST_PREFIX which will be used by the 'fail.cmake' files.
  set(TEST_PREFIX "${REPO_NAME}")
  set(FAILING_TESTS)
  set(SKIP_TESTS)
  include("${REPO_PATH}/test/fail.cmake" OPTIONAL)
  include("${REPO_PATH}/tests/fail.cmake" OPTIONAL)

  foreach(FILE ${TEST_FILES})
    set(TEST_NAME "${REPO_NAME}/${FILE}")
    if("${TEST_NAME}" IN_LIST SKIP_TESTS OR "${TEST_NAME}" IN_LIST TOIT_SKIP_TESTS)
      continue()
    endif()

    set(TEST_EXPECTATION_NAME "${TEST_NAME}")
    if("${TEST_NAME}" IN_LIST FAILING_TESTS OR "${TEST_NAME}" IN_LIST TOIT_FAILING_TESTS)
      set(TEST_EXPECTATION_NAME "${TEST_NAME}-expected-to-fail")
    endif()

    add_test(
      NAME "${TEST_EXPECTATION_NAME}"
      COMMAND $<TARGET_FILE:toit.run> "${FILE}" $<TARGET_FILE:toit.run>
      WORKING_DIRECTORY "${REPO_PATH}"
      CONFIGURATIONS external
    )
    if("${TEST_NAME}" IN_LIST FAILING_TESTS OR "${TEST_NAME}" IN_LIST TOIT_FAILING_TESTS)
      set_tests_properties(${TEST_EXPECTATION_NAME} PROPERTIES WILL_FAIL TRUE)
    endif()

    if ("${TEST_NAME}" MATCHES "_slow\\.toit$")
      set_tests_properties(${TEST_EXPECTATION_NAME} PROPERTIES TIMEOUT ${SLOW_TIMEOUT})
    else()
      set_tests_properties(${TEST_EXPECTATION_NAME} PROPERTIES TIMEOUT ${DEFAULT_TIMEOUT})
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

  file(RELATIVE_PATH RELATIVE_FILE "${CMAKE_CURRENT_LIST_DIR}" "${FILE}")
  if ("health-external/${RELATIVE_FILE}" IN_LIST TOIT_SKIP_TESTS)
    continue()
  endif()

  add_health_test("${FILE}"
    RELATIVE_TO "${DOWNLOADS_DIR}"
    LIB_DIR "${TOIT_SDK_SOURCE_DIR}/lib"
    GOLD_DIR "${EXTERNAL_GOLD_DIR}"
    CONFIGURATION external_health
    SHOW_PACKAGE_WARNINGS OFF
    UPDATE_TARGET update_external_health_gold
  )
endforeach()
