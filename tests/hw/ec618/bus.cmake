# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by the license in the LICENSE file.

option(EC618_TEST_BUSES "Enable coordinated FPC I2C/UART/SPI tests with resident fixtures" "$ENV{EC618_TEST_BUSES}")
set(EC618_BUS_TARGET_PORT "$ENV{EC618_BUS_TARGET_PORT}" CACHE FILEPATH "Persistent S3 FPC fixture console")
set(EC618_BUS_BRIDGE "$ENV{EC618_BUS_BRIDGE}" CACHE STRING "Classic ESP32 UART1 bridge address")
if(EC618_TEST_BUSES)
  if(NOT EC618_BOARD_PORT OR NOT EC618_EXPECT_BASE OR NOT EC618_BUS_TARGET_PORT OR NOT EC618_BUS_BRIDGE)
    message(FATAL_ERROR "FPC bus tests require board/target ports, expected base and bridge address")
  endif()
  find_program(EC618_FLOCK flock REQUIRED)
  get_filename_component(bus_root "${CMAKE_CURRENT_SOURCE_DIR}/../../.." ABSOLUTE)
  set(bus_lock "${EC618_RIG_LOCK}")
  if(NOT bus_lock)
    set(bus_lock "/tmp/toit-ec618-rig.lock")
  endif()
  foreach(case dual-i2c-matrix uart uart-alt spi)
    add_test(NAME "fpc-${case}-ec618"
        COMMAND "${EC618_FLOCK}" -n "${bus_lock}"
            "${TOIT_EXE_HW}" run tests/hw/esp-tester/run-ec618-bus.toit --
            --port "${EC618_BOARD_PORT}" --toit-exe "${TOIT_EXE_HW}"
            --expected-base "${EC618_EXPECT_BASE}" --target-port "${EC618_BUS_TARGET_PORT}"
            --bridge "${EC618_BUS_BRIDGE}" --case "${case}"
        CONFIGURATIONS ec618)
    set_tests_properties("fpc-${case}-ec618" PROPERTIES
        WORKING_DIRECTORY "${bus_root}" TIMEOUT 460 RESOURCE_LOCK ec618-rig
        LABELS "ec618;hardware;fpc-bus")
  endforeach()
endif()
