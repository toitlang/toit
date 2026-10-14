# Copyright (C) 2026 Toit contributors.
cmake_minimum_required(VERSION 3.20)

option(EC618_OBSERVER_HOST_TESTS "Build the observer's host fault tests instead of firmware" OFF)
if(EC618_OBSERVER_HOST_TESTS)
  project(ec618_spi_observer_tests LANGUAGES C)
  enable_testing()
  find_program(TOIT_EXECUTABLE toit REQUIRED)
  foreach(kind verify wire continuous)
    add_executable(observer-${kind} ${kind}-test.c)
    target_compile_options(observer-${kind} PRIVATE -Wall -Wextra -Werror -UNDEBUG)
  endforeach()
  # This test uses the header's sample generator but not its native receiver.
  target_compile_options(observer-wire PRIVATE -Wno-unused-function)
  add_custom_command(OUTPUT "${CMAKE_BINARY_DIR}/reference24.bin"
      COMMAND "${TOIT_EXECUTABLE}" run "${CMAKE_CURRENT_LIST_DIR}/export-pattern.toit" --
          24 "${CMAKE_BINARY_DIR}/reference24.bin"
      DEPENDS export-pattern.toit ../../shared/i2s-pattern.toit VERBATIM)
  add_custom_target(observer-reference ALL DEPENDS "${CMAKE_BINARY_DIR}/reference24.bin")
  add_test(NAME observer-verify COMMAND observer-verify)
  add_test(NAME observer-wire COMMAND observer-wire 24 "${CMAKE_BINARY_DIR}/reference24.bin")
  add_test(NAME observer-continuous COMMAND observer-continuous "${CMAKE_BINARY_DIR}/reference24.bin")
  add_test(NAME observer-verdicts
      COMMAND "${TOIT_EXECUTABLE}" run "${CMAKE_CURRENT_LIST_DIR}/verdict-test.toit" --
          "${TOIT_EXECUTABLE}" "${CMAKE_CURRENT_LIST_DIR}")
  return()
endif()

# This diagnostic uses private SPI DMA state. Pin its SDK and patch a build-local
# component copy, never the shared ESP-IDF checkout used by other firmware.
set(observer_idf "$ENV{IDF_PATH}")
find_package(Git REQUIRED)
execute_process(COMMAND "${GIT_EXECUTABLE}" -C "${observer_idf}" rev-parse HEAD
    OUTPUT_VARIABLE observer_revision OUTPUT_STRIP_TRAILING_WHITESPACE
    COMMAND_ERROR_IS_FATAL ANY)
if(NOT observer_revision STREQUAL "defb08e5592ba3c26f602376c027d7dda835c2f1")
  message(FATAL_ERROR "The SPI observer requires ESP-IDF defb08e5592ba3c26f602376c027d7dda835c2f1")
endif()
set(observer_spi "${observer_idf}/components/esp_driver_spi")
file(SHA256 "${observer_spi}/src/gpspi/spi_slave.c" observer_spi_hash)
if(NOT observer_spi_hash STREQUAL "e566db64b79dbedf686e10eddbea5bce8f405eb251b435dce2adcc043d9b2e43")
  message(FATAL_ERROR "The SPI observer requires the unmodified pinned SPI driver")
endif()
set(observer_components "${CMAKE_BINARY_DIR}/observer-components")
file(MAKE_DIRECTORY "${observer_components}")
file(COPY "${observer_spi}" DESTINATION "${observer_components}")
execute_process(COMMAND "${GIT_EXECUTABLE}" apply --no-index --unidiff-zero
    "${CMAKE_CURRENT_LIST_DIR}/spi-slave.patch"
    WORKING_DIRECTORY "${observer_components}/esp_driver_spi"
    COMMAND_ERROR_IS_FATAL ANY)
set(EXTRA_COMPONENT_DIRS "${observer_components}/esp_driver_spi")

include("${observer_idf}/tools/cmake/project.cmake")
project(ec618_spi_observer)
