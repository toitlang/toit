# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by the LGPL-2.1 license that can be
# found in the LICENSE file.

cmake_minimum_required(VERSION 3.20...4.0)

# Like the ESP-IDF projects, the Pico SDK owns compiler selection and linking.
# It must be imported before project(). Keep this separate from the host build.
get_filename_component(TOIT_ROOT "${CMAKE_CURRENT_LIST_DIR}/../.." ABSOLUTE)
if (NOT PICO_SDK_PATH)
  if (DEFINED ENV{PICO_SDK_PATH})
    set(PICO_SDK_PATH "$ENV{PICO_SDK_PATH}")
  else()
    set(PICO_SDK_PATH "${TOIT_ROOT}/third_party/pico-sdk")
  endif()
endif()
if (NOT EXISTS "${PICO_SDK_PATH}/pico_sdk_init.cmake")
  message(FATAL_ERROR "Pico SDK missing. Run bash tools/rp2350/setup.sh first.")
endif()

set(PICO_BOARD weact_studio_rp2350b_core CACHE STRING "RP2350 board")
set(PICO_PLATFORM rp2350-arm-s CACHE STRING "Pico platform")
if (NOT PICO_PLATFORM STREQUAL "rp2350-arm-s")
  message(FATAL_ERROR "The initial Toit port targets rp2350-arm-s.")
endif()
if (NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()
if (NOT picotool_DIR AND EXISTS "${TOIT_ROOT}/.cache/rp2350/install/lib/cmake/picotool")
  set(picotool_DIR "${TOIT_ROOT}/.cache/rp2350/install/lib/cmake/picotool")
endif()
# Configuration/build must not silently fetch an unpinned host tool.
if (NOT picotool_DIR)
  message(FATAL_ERROR "Set picotool_DIR or run bash tools/rp2350/setup.sh first.")
endif()
find_package(picotool 2.3.1 EXACT CONFIG REQUIRED)

include("${PICO_SDK_PATH}/pico_sdk_init.cmake")
project(toit_rp2350 C CXX ASM)
set(CMAKE_C_STANDARD 11)
set(CMAKE_CXX_STANDARD 11)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
pico_sdk_init()

if (NOT TARGET tinyusb_device)
  message(FATAL_ERROR "TinyUSB missing. Initialize the Pico SDK lib/tinyusb submodule.")
endif()

# Native hardware validation, kept available during VM bring-up and recovery.
add_executable(toit-rp2350-bringup bringup.c)
target_link_libraries(toit-rp2350-bringup PRIVATE pico_stdlib pico_unique_id hardware_uart)
target_compile_options(toit-rp2350-bringup PRIVATE -Wall -Wextra)
set(TOIT_RP2350_UART_TX_PIN 16 CACHE STRING "UART0 TX to ESP32 GPIO34")
set(TOIT_RP2350_UART_RX_PIN 1 CACHE STRING "UART0 RX from ESP32 GPIO4")
target_compile_definitions(toit-rp2350-bringup PRIVATE
  TOIT_RP2350_UART_TX_PIN=${TOIT_RP2350_UART_TX_PIN}
  TOIT_RP2350_UART_RX_PIN=${TOIT_RP2350_UART_RX_PIN}
  PICO_STDIO_USB_STDOUT_TIMEOUT_US=1000
)
pico_enable_stdio_usb(toit-rp2350-bringup 1)
pico_enable_stdio_uart(toit-rp2350-bringup 0)
pico_set_program_name(toit-rp2350-bringup "Toit RP2350 bring-up")
pico_set_program_version(toit-rp2350-bringup "0.1")
pico_add_extra_outputs(toit-rp2350-bringup)

add_executable(toit-rp2350-rig-test rig_test.c)
target_link_libraries(toit-rp2350-rig-test PRIVATE pico_stdlib pico_unique_id hardware_uart hardware_adc)
target_compile_options(toit-rp2350-rig-test PRIVATE -Wall -Wextra)
target_compile_definitions(toit-rp2350-rig-test PRIVATE
  TOIT_RP2350_UART_TX_PIN=${TOIT_RP2350_UART_TX_PIN}
  TOIT_RP2350_UART_RX_PIN=${TOIT_RP2350_UART_RX_PIN}
  PICO_STDIO_USB_STDOUT_TIMEOUT_US=1000)
pico_enable_stdio_usb(toit-rp2350-rig-test 1)
pico_enable_stdio_uart(toit-rp2350-rig-test 0)
pico_set_program_name(toit-rp2350-rig-test "Toit RP2350 rig test")
pico_set_program_version(toit-rp2350-rig-test "0.1")
pico_add_extra_outputs(toit-rp2350-rig-test)

set(TOIT_OTA_PROBE_VERSION 1 CACHE STRING "Native OTA test image version")
add_executable(toit-rp2350-ota-probe ota_probe.c)
target_link_libraries(toit-rp2350-ota-probe PRIVATE pico_stdlib pico_bootrom)
target_compile_definitions(toit-rp2350-ota-probe PRIVATE
  TOIT_OTA_PROBE_VERSION=${TOIT_OTA_PROBE_VERSION}
  PICO_CRT0_IMAGE_TYPE_TBYB=1
  PICO_FLASH_ASSUME_CORE1_SAFE=1
  PICO_STDIO_USB_STDOUT_TIMEOUT_US=1000)
pico_enable_stdio_usb(toit-rp2350-ota-probe 1)
pico_enable_stdio_uart(toit-rp2350-ota-probe 0)
pico_set_program_name(toit-rp2350-ota-probe "Toit RP2350 OTA probe")
pico_set_binary_version(toit-rp2350-ota-probe MAJOR ${TOIT_OTA_PROBE_VERSION})
pico_hash_binary(toit-rp2350-ota-probe)
pico_add_extra_outputs(toit-rp2350-ota-probe)

option(TOIT_RP2350_BUILD_VM "Build the Toit VM" OFF)
if (TOIT_RP2350_BUILD_VM)
  if (NOT PICO_CLIB STREQUAL "newlib")
    message(FATAL_ERROR "The RP2350 VM currently requires newlib allocation hooks.")
  endif()
  set(FREERTOS_KERNEL_PATH "${TOIT_ROOT}/third_party/FreeRTOS-Kernel")
  set(FREERTOS_CONFIG_FILE_DIRECTORY "${CMAKE_CURRENT_LIST_DIR}/include")
  set(RP2350_FREERTOS_PORT "${FREERTOS_KERNEL_PATH}/portable/ThirdParty/Community-Supported-Ports/GCC/RP2350_ARM_NTZ")
  include("${RP2350_FREERTOS_PORT}/FreeRTOS_Kernel_import.cmake")

  set(TOIT_SYSTEM_NAME rp2350)
  set(TOIT_MODEL weact_studio_rp2350b_core)
  include_directories("${CMAKE_CURRENT_LIST_DIR}/include"
    "${FREERTOS_KERNEL_PATH}/include" "${RP2350_FREERTOS_PORT}/non_secure")
  add_compile_definitions(TOIT_RP2350 __FREERTOS__ RAW CONFIG_TOIT_CRYPTO=1 PICO_STDIO_USB_LOW_PRIORITY_IRQ=51)
  add_subdirectory("${TOIT_ROOT}" toit EXCLUDE_FROM_ALL)
  foreach(target toit_vm mbedtls mbedcrypto mbedx509)
    set_property(TARGET ${target} PROPERTY C_STANDARD 11)
    target_link_libraries(${target} PRIVATE pico_stdlib_headers hardware_clocks_headers hardware_sync_headers)
  endforeach()
  target_link_libraries(toit_vm PRIVATE pico_rand_headers pico_bootrom_headers boot_picobin_headers pico_stdio_usb_headers hardware_adc_headers hardware_uart_headers hardware_i2c_headers hardware_spi_headers hardware_dma_headers hardware_pwm_headers hardware_powman_headers)

  set(TOIT_HOST "${TOIT_ROOT}/build/host/sdk/bin/toit" CACHE FILEPATH "Matching host Toit compiler")
  set(TOIT_RP2350_PROGRAM "${TOIT_ROOT}/tests/hw/rp2350/vm-smoke.toit" CACHE FILEPATH "Boot program")
  option(TOIT_RP2350_OTA "Include the firmware service and USB update console" ON)
  option(TOIT_RP2350_ENVELOPE_BASE "Build the VM base for envelope extraction" OFF)
  if (TOIT_RP2350_ENVELOPE_BASE AND NOT TOIT_RP2350_OTA)
    message(FATAL_ERROR "Envelope bases must enable RP2350 OTA metadata.")
  endif()
  option(TOIT_RP2350_AUTO_VALIDATE "Confirm trial firmware after VM/service startup" ON)
  set(TOIT_RP2350_VERSION 1 CACHE STRING "ROM firmware major version (0..65535)")
  if (NOT EXISTS "${TOIT_HOST}")
    message(FATAL_ERROR "Build the matching host tools first: make host-tools")
  endif()
  function(toit_relative_import out path)
    file(RELATIVE_PATH relative "${CMAKE_CURRENT_BINARY_DIR}" "${path}")
    string(REGEX REPLACE "[.]toit$" "" relative "${relative}")
    string(REPLACE "../" "." relative "${relative}")
    string(REPLACE "/" "." relative "${relative}")
    set(${out} ".${relative}" PARENT_SCOPE)
  endfunction()
  toit_relative_import(TOIT_SERVICE_IMPORT "${TOIT_ROOT}/system/services.toit")
  toit_relative_import(TOIT_APPLICATION_IMPORT "${TOIT_RP2350_PROGRAM}")
  if (TOIT_RP2350_OTA)
    toit_relative_import(TOIT_PLATFORM_IMPORT "${TOIT_ROOT}/system/extensions/rp2350/initialize.toit")
    toit_relative_import(TOIT_OTA_IMPORT "${CMAKE_CURRENT_LIST_DIR}/ota-console.toit")
    if (TOIT_RP2350_AUTO_VALIDATE)
      set(TOIT_AUTO_VALIDATE_VALUE true)
    else()
      set(TOIT_AUTO_VALIDATE_VALUE false)
    endif()
    configure_file(boot-ota.toit.in boot.toit @ONLY)
    configure_file(application.toit.in application.toit @ONLY)
  else()
    configure_file(boot.toit.in boot.toit @ONLY)
  endif()
  file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/package.yaml" "name: rp2350-boot\n")
  file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/package.lock" "# No external packages.\n")
  file(GLOB_RECURSE TOIT_LIBRARY_SOURCES "${TOIT_ROOT}/lib/*.toit")
  file(GLOB TOIT_RP2350_TEST_SOURCES "${TOIT_ROOT}/tests/hw/rp2350/*.toit")
  file(GLOB_RECURSE TOIT_SYSTEM_SOURCES CONFIGURE_DEPENDS "${TOIT_ROOT}/system/*.toit")
  set(TOIT_RP2350_ASSETS "" CACHE FILEPATH "Encoded assets for the boot program")
  set(TOIT_IMAGE_ASSET_ARGS)
  if (TOIT_RP2350_ASSETS)
    list(APPEND TOIT_IMAGE_ASSET_ARGS "--assets=${TOIT_RP2350_ASSETS}")
  endif()
  set(TOIT_BOOT_ASSET_ARGS ${TOIT_IMAGE_ASSET_ARGS})
  set(TOIT_APPLICATION_COMMANDS)
  set(TOIT_APPLICATION_DEPENDENCIES)
  set(TOIT_BUNDLED_IMAGES)
  if (TOIT_RP2350_OTA)
    # The application runs as an independent noncritical container. Keep its
    # assets with that container and leave the update service alive on failure.
    set(TOIT_BOOT_ASSET_ARGS)
    list(APPEND TOIT_APPLICATION_COMMANDS
      COMMAND "${TOIT_HOST}" compile -s -o application.snapshot application.toit
      COMMAND "${TOIT_HOST}" tool snapshot-to-image --format=binary -m32 ${TOIT_IMAGE_ASSET_ARGS}
        -o application.image application.snapshot)
    list(APPEND TOIT_BUNDLED_IMAGES application.image)
    list(APPEND TOIT_APPLICATION_DEPENDENCIES "${CMAKE_CURRENT_BINARY_DIR}/application.toit")
  endif()
  add_custom_command(OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/boot.S"
    COMMAND "${TOIT_HOST}" compile -s -o boot.snapshot boot.toit
    COMMAND "${TOIT_HOST}" tool snapshot-to-image --format=binary -m32 ${TOIT_BOOT_ASSET_ARGS} -o boot.image boot.snapshot
    ${TOIT_APPLICATION_COMMANDS}
    COMMAND "${TOIT_HOST}" run "${TOIT_ROOT}/tools/rp2350/image-to-assembly.toit" -- boot.image boot.S ${TOIT_BUNDLED_IMAGES}
    DEPENDS "${TOIT_RP2350_PROGRAM}" ${TOIT_LIBRARY_SOURCES} ${TOIT_RP2350_TEST_SOURCES}
      "${CMAKE_CURRENT_BINARY_DIR}/boot.toit" "${TOIT_ROOT}/system/services.toit"
      ${TOIT_APPLICATION_DEPENDENCIES}
      "${CMAKE_CURRENT_LIST_DIR}/application.toit.in"
      "${CMAKE_CURRENT_LIST_DIR}/ota-console.toit" ${TOIT_SYSTEM_SOURCES}
      ${TOIT_RP2350_ASSETS}
      "${TOIT_ROOT}/tools/rp2350/image-to-assembly.toit" "${TOIT_HOST}"
    VERBATIM)
  if (TOIT_RP2350_ENVELOPE_BASE)
    add_executable(toit-rp2350 main.cc failure.cc envelope-stub.S)
  else()
    add_executable(toit-rp2350 main.cc failure.cc "${CMAKE_CURRENT_BINARY_DIR}/boot.S")
  endif()
  set(TOIT_RP2350_TEST_FAULT "" CACHE STRING "Test-only native failure: abort, exit, fatal, panic, hardfault, xip-fault, stack-overflow, watchdog-hang")
  if (TOIT_RP2350_TEST_FAULT)
    if (TOIT_RP2350_ENVELOPE_BASE OR NOT TOIT_RP2350_OTA)
      message(FATAL_ERROR "Fault injection requires a bring-up OTA image, not an envelope base.")
    endif()
    if (NOT TOIT_RP2350_TEST_FAULT MATCHES "^(abort|exit|fatal|panic|hardfault|xip-fault|stack-overflow|watchdog-hang)$")
      message(FATAL_ERROR "Unknown TOIT_RP2350_TEST_FAULT")
    endif()
    target_sources(toit-rp2350 PRIVATE failure-test.cc)
    target_compile_definitions(toit-rp2350 PRIVATE TOIT_RP2350_TEST_FAULT="${TOIT_RP2350_TEST_FAULT}")
  endif()
  target_include_directories(toit-rp2350 PRIVATE "${TOIT_ROOT}/src"
    "${TOIT_ROOT}/include" "${PICO_SDK_PATH}/lib/mbedtls/include")
  target_compile_definitions(toit-rp2350 PRIVATE
    PICO_CXX_DISABLE_ALLOCATION_OVERRIDES=1
    PICO_MALLOC_PANIC=0
    PICO_USE_MALLOC_MUTEX=0
    PICO_FLASH_ASSUME_CORE1_SAFE=1
    PICO_PANIC_FUNCTION=toit_rp2350_panic
    PICO_PANIC_FUNCTION_DOES_NOT_RETURN=1
    MBEDTLS_CONFIG_FILE="${TOIT_ROOT}/mbedtls/include/rp2350_config.h"
    PICO_STDIO_USB_STDOUT_TIMEOUT_US=1000)
  target_link_libraries(toit-rp2350 PRIVATE
    -Wl,--whole-archive toit_vm -Wl,--no-whole-archive
    mbedtls mbedx509 mbedcrypto pico_stdlib pico_rand pico_unique_id pico_low_power hardware_adc hardware_uart hardware_i2c hardware_spi hardware_dma hardware_pwm
    FreeRTOS-Kernel-Heap3)
  pico_enable_stdio_usb(toit-rp2350 1)
  pico_enable_stdio_uart(toit-rp2350 0)
  pico_set_program_name(toit-rp2350 "Toit RP2350")
  if (TOIT_RP2350_OTA)
    target_compile_definitions(toit-rp2350 PRIVATE PICO_CRT0_IMAGE_TYPE_TBYB=1)
    pico_set_binary_version(toit-rp2350 MAJOR ${TOIT_RP2350_VERSION})
    pico_hash_binary(toit-rp2350)
  endif()
  pico_add_extra_outputs(toit-rp2350)
endif()
