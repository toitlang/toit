# Copyright (C) 2024 Toitware ApS.
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

file(GLOB SINGLE_TESTS RELATIVE ${CMAKE_CURRENT_SOURCE_DIR} "*-test.toit")
file(GLOB MULTI_TESTS RELATIVE ${CMAKE_CURRENT_SOURCE_DIR} "*-board1.toit")

set(TESTER ${CMAKE_CURRENT_SOURCE_DIR}/../esp-tester/tester.toit)

add_custom_target(
  check_esp32
  COMMAND ${CMAKE_CTEST_COMMAND} -j2 -T test -C esp32 --output-on-failure
  USES_TERMINAL
  )

add_custom_target(
  check_esp32s3
  COMMAND ${CMAKE_CTEST_COMMAND} -j2 -T test -C esp32s3 --output-on-failure
  USES_TERMINAL
)

include(fail.cmake OPTIONAL)

set(VARIANTS
  esp32
  esp32s3
  )

foreach(esp_variant ${VARIANTS})
  string(TOUPPER ${esp_variant} ESP_VARIANT)
  foreach(board board1 board2)
    string(TOUPPER ${board} BOARD)
    set(port "$ENV{${ESP_VARIANT}_${BOARD}_PORT}")
    set(test_name "setup-${board}-${esp_variant}")
    add_test(
      NAME ${test_name}
      COMMAND "${TOIT_EXE_HW}" "${TESTER}" setup
          --verbose
          --toit-exe "${TOIT_EXE_HW}"
          --port "${port}"
          --envelope "$ENV{${ESP_VARIANT}_ENVELOPE}"
          # Typically the SSID and password are the same for all variants, but
          # this makes it more consistent.
          --wifi-ssid "$ENV{${ESP_VARIANT}_WIFI_SSID}"
          --wifi-password "$ENV{${ESP_VARIANT}_WIFI_PASSWORD}"
      WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
      CONFIGURATIONS ${esp_variant} hw
      )

    set_tests_properties("${test_name}" PROPERTIES TIMEOUT 80)
    set_tests_properties("${test_name}" PROPERTIES FIXTURES_SETUP "setup-boards-${esp_variant}")
  endforeach()
endforeach()

function(parse_args_from_file file_path result_var)
  # Ensure the provided file exists.
  if(NOT EXISTS "${file_path}")
    message(FATAL_ERROR "File not found: ${file_path}")
  endif()

  # Read the file content.
  file(READ "${file_path}" file_content)

  # Initialize the result list.
  set(result_list)

  # Use a regular expression to find a line that starts with "// ARG: ".
  string(REGEX MATCHALL "// ARG: [^\n]+" matched_lines "${file_content}")

  foreach(line IN LISTS matched_lines)
    # Extract the part after "// ARG: ".
    string(REGEX REPLACE "^// ARG: " "" args_string "${line}")

    # Split the string by spaces and append to the result list.
    string(REGEX MATCHALL "[^ \t]+" args_list "${args_string}")
    list(APPEND result_list ${args_list})
  endforeach()

  # If no matching line was found, set result_list to an empty string.
  if(NOT result_list)
    set(result_list "**NO_ARG**")
  endif()

  # Set the result variable.
  set(${result_var} ${result_list} PARENT_SCOPE)
endfunction()

function(parse_wireless_from_file file_path result_var)
  # Ensure the provided file exists.
  if(NOT EXISTS "${file_path}")
    message(FATAL_ERROR "File not found: ${file_path}")
  endif()

  # Read the file content.
  file(READ "${file_path}" file_content)

  # Use a regular expression to find a line that starts with "// WIRELESS".
  string(REGEX MATCHALL "\n// WIRELESS" matched_lines "${file_content}")

  # If we have a match, return it.
  if(matched_lines)
    set(${result_var} "WIRELESS" PARENT_SCOPE)
  endif()
endfunction()

foreach(esp_variant ${VARIANTS})
  string(TOUPPER ${esp_variant} ESP_VARIANT)
  foreach(file ${SINGLE_TESTS})
    set(flaky FALSE)
    set(toit_file ${CMAKE_CURRENT_SOURCE_DIR}/${file})
    parse_args_from_file(${toit_file} args)
    unset(wireless)
    parse_wireless_from_file(${toit_file} wireless)
    if (NOT "${wireless}" STREQUAL "")
      # We consider all wireless tests to be flaky.
      set(flaky TRUE)
    endif()

    foreach(arg ${args})
      set(test_name ${file}-${esp_variant})
      if (NOT ${arg} STREQUAL "**NO_ARG**")
        set(test_name "${test_name}-${arg}")
      endif()

      if ("${test_name}" IN_LIST TOIT_SKIP_TESTS)
        continue()
      endif()

      set(failing FALSE)
      if ("${test_name}" IN_LIST TOIT_FAILING_TESTS)
        set(test_name "${test_name}-failing")
        set(failing TRUE)
      endif()

      unset(flaky_flag)
      if (flaky)
        # Call flaky.sh of this directory.
        set(flaky_flag "--flaky")
      endif()

      add_test(
        NAME ${test_name}
        COMMAND ${TOIT_EXE_HW} "${TESTER}" run ${toit_file}
            ${flaky_flag}
            --arg "${arg}"
            --verbose
            --toit-exe "${TOIT_EXE_HW}"
            --port-board1 "$ENV{${ESP_VARIANT}_BOARD1_PORT}"
        WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
        CONFIGURATIONS ${esp_variant} hw
        )

      set (timeout 120)
      if (${flaky})
        set(timeout 360)
      endif()
      set_tests_properties(${test_name} PROPERTIES TIMEOUT ${timeout})
      set_tests_properties(${test_name} PROPERTIES FIXTURES_REQUIRED "setup-boards-${esp_variant}")
      if (wireless)
        set_tests_properties("${test_name}" PROPERTIES RESOURCE_LOCK "${esp_variant};${wireless}")
      else()
        set_tests_properties("${test_name}" PROPERTIES RESOURCE_LOCK ${esp_variant})
      endif()

      if (${failing})
        set_tests_properties(${test_name} PROPERTIES WILL_FAIL TRUE)
      endif()
    endforeach()
  endforeach()

  foreach(file ${MULTI_TESTS})
    set(flaky FALSE)
    set(toit_file ${CMAKE_CURRENT_SOURCE_DIR}/${file})
    parse_args_from_file(${toit_file} args)
    unset(wireless)
    parse_wireless_from_file(${toit_file} wireless)
    if (NOT "${wireless}" STREQUAL "")
      # We consider all wireless tests to be flaky.
      set(flaky TRUE)
    endif()

    foreach(arg ${args})
      set(test_name ${file}-${esp_variant})
      if (NOT ${arg} STREQUAL "**NO_ARG**")
        set(test_name "${test_name}-${arg}")
      endif()

      if ("${test_name}" IN_LIST TOIT_SKIP_TESTS)
        continue()
      endif()

      set(failing FALSE)
      if ("${test_name}" IN_LIST TOIT_FAILING_TESTS)
        set(test_name "${test_name}-failing")
        set(failing TRUE)
      endif()

      string(REPLACE "board1" "board2" toit_file_board2 ${toit_file})

      unset(flaky_flag)
      if (flaky)
        set(flaky_flag "--flaky")
      endif()

      add_test(
        NAME "${test_name}"
        COMMAND ${TOIT_EXE_HW} "${TESTER}" run ${toit_file} ${toit_file_board2}
            ${flaky_flag}
            --verbose
            --arg "${arg}"
            --toit-exe "${TOIT_EXE_HW}"
            --port-board1 "$ENV{${ESP_VARIANT}_BOARD1_PORT}"
            --port-board2 "$ENV{${ESP_VARIANT}_BOARD2_PORT}"
        WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
        CONFIGURATIONS ${esp_variant} hw
        )

      set (timeout 120)
      if (${flaky})
        set(timeout 360)
      endif()
      set_tests_properties("${test_name}" PROPERTIES TIMEOUT ${timeout})
      set_tests_properties("${test_name}" PROPERTIES FIXTURES_REQUIRED "setup-boards-${esp_variant}")
      if (wireless)
        set_tests_properties("${test_name}" PROPERTIES RESOURCE_LOCK "${esp_variant};${wireless}")
      else()
        set_tests_properties("${test_name}" PROPERTIES RESOURCE_LOCK ${esp_variant})
      endif()

      if (${failing})
        set_tests_properties("${test_name}" PROPERTIES WILL_FAIL TRUE)
      endif()
    endforeach()
  endforeach()
endforeach()
