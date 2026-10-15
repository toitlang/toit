# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by the license in the LICENSE file.

option(EC618_TEST_STANDALONE "Enable regressions on an already provisioned EC618" "$ENV{EC618_TEST_STANDALONE}")
option(EC618_TEST_FPC "Enable I2S allocation and stop tests on the wired FPC rig" "$ENV{EC618_TEST_FPC}")
option(EC618_TEST_I2S_MASTER "Enable live-clock stop test; disconnect DS18B20 and leave peer clock pins as inputs" "$ENV{EC618_TEST_I2S_MASTER}")
if(EC618_TEST_STANDALONE OR EC618_TEST_FPC OR EC618_TEST_I2S_MASTER)
  if(NOT EC618_BOARD_PORT OR NOT EC618_EXPECT_BASE)
    message(FATAL_ERROR "EC618 standalone tests require EC618_BOARD_PORT and EC618_EXPECT_BASE")
  endif()
  find_program(EC618_FLOCK flock REQUIRED)
  get_filename_component(ec618_root "${CMAKE_CURRENT_SOURCE_DIR}/../../.." ABSOLUTE)
  set(ec618_lock "${EC618_RIG_LOCK}")
  if(NOT ec618_lock)
    set(ec618_lock "/tmp/toit-ec618-rig.lock")
  endif()
  function(ec618_standalone name file)
    if(NOT EXISTS "${ec618_root}/${file}")
      message(FATAL_ERROR "Missing EC618 test source: ${file}")
    endif()
    add_test(NAME "${name}"
        COMMAND "${EC618_FLOCK}" -n "${ec618_lock}"
            "${TOIT_EXE_HW}" run tests/hw/esp-tester/run-ec618-standalone.toit --
            --port "${EC618_BOARD_PORT}" --toit-exe "${TOIT_EXE_HW}"
            --expected-base "${EC618_EXPECT_BASE}" --test "${file}"
        CONFIGURATIONS ec618)
    set_tests_properties("${name}" PROPERTIES
        WORKING_DIRECTORY "${ec618_root}" TIMEOUT 240 RESOURCE_LOCK ec618-rig
        LABELS "ec618;hardware;standalone")
  endfunction()
  if(EC618_TEST_STANDALONE)
    foreach(file basics adc-lifecycle-ec618 adc-events-ec618 cellular-lifecycle-ec618 watchdog-stop-ec618 firmware-writer-lifecycle-ec618)
      string(REGEX REPLACE "-ec618$" "" name "${file}")
      ec618_standalone("${name}-ec618" "tests/hw/ec618/${file}.toit")
    endforeach()
    ec618_standalone(integer-literal-width-ec618 "tests/regress/integer-literal-width-test.toit")
  endif()
  if(EC618_TEST_FPC)
    foreach(file i2s-stop-ec618 i2s-buffer-capacity-ec618)
      ec618_standalone("${file}" "tests/hw/ec618/${file}.toit")
    endforeach()
  endif()
  if(EC618_TEST_I2S_MASTER)
    ec618_standalone(i2s-live-stop-ec618 "tests/hw/ec618/i2s-live-stop-ec618.toit")
  endif()
endif()
