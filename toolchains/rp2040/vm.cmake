# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by the LGPL-2.1 license in LICENSE.
set(FREERTOS_KERNEL_PATH "${TOIT_ROOT}/third_party/FreeRTOS-Kernel")
set(FREERTOS_CONFIG_FILE_DIRECTORY "${TOIT_ROOT}/toolchains/rp2350/include")
set(RP2040_FREERTOS_PORT "${FREERTOS_KERNEL_PATH}/portable/ThirdParty/GCC/RP2040")
include("${RP2040_FREERTOS_PORT}/FreeRTOS_Kernel_import.cmake")
set(TOIT_SYSTEM_NAME rp2040)
set(TOIT_MODEL "${PICO_BOARD}")
include_directories("${FREERTOS_CONFIG_FILE_DIRECTORY}" "${FREERTOS_KERNEL_PATH}/include"
  "${RP2040_FREERTOS_PORT}/include")
add_compile_definitions(TOIT_RP2040 __FREERTOS__ RAW CONFIG_TOIT_CRYPTO=1 PICO_STDIO_USB_LOW_PRIORITY_IRQ=31)
add_subdirectory("${TOIT_ROOT}" toit EXCLUDE_FROM_ALL)
foreach(target toit_vm mbedtls mbedcrypto mbedx509)
  set_property(TARGET ${target} PROPERTY C_STANDARD 11)
  target_link_libraries(${target} PRIVATE pico_stdlib_headers hardware_clocks_headers hardware_sync_headers)
endforeach()
target_link_libraries(toit_vm PRIVATE pico_rand_headers pico_stdio_usb_headers pico_unique_id_headers
  hardware_flash_headers hardware_adc_headers hardware_uart_headers hardware_i2c_headers
  hardware_spi_headers hardware_dma_headers hardware_pwm_headers hardware_pio_headers)

set(TOIT_HOST "${TOIT_ROOT}/build/host/sdk/bin/toit" CACHE FILEPATH "Matching host compiler")
set(TOIT_RP2040_PROGRAM "${TOIT_ROOT}/tests/hw/rp2040/vm-smoke.toit" CACHE FILEPATH "Application")
get_filename_component(TOIT_APPLICATION_DIR "${TOIT_RP2040_PROGRAM}" DIRECTORY)
set(TOIT_RP2040_PROJECT_ROOT "" CACHE PATH "Application package root (defaults to source directory)")
if (NOT TOIT_RP2040_PROJECT_ROOT)
  set(TOIT_RP2040_PROJECT_ROOT "${TOIT_APPLICATION_DIR}")
endif()
file(GLOB_RECURSE TOIT_LIBRARY_SOURCES CONFIGURE_DEPENDS "${TOIT_ROOT}/lib/*.toit")
file(GLOB_RECURSE TOIT_SYSTEM_SOURCES CONFIGURE_DEPENDS "${TOIT_ROOT}/system/*.toit")
set(TOIT_PACKAGE_INPUTS)
foreach(name package.yaml package.lock)
  if (EXISTS "${TOIT_RP2040_PROJECT_ROOT}/${name}")
    list(APPEND TOIT_PACKAGE_INPUTS "${TOIT_RP2040_PROJECT_ROOT}/${name}")
  endif()
endforeach()
add_custom_command(OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/boot.snapshot"
  COMMAND "${TOIT_HOST}" compile -s -o boot.snapshot
    --dependency-file boot.dep --dependency-format ninja
    "${TOIT_ROOT}/system/extensions/rp2040/boot.toit"
  DEPFILE "${CMAKE_CURRENT_BINARY_DIR}/boot.dep"
  DEPENDS ${TOIT_LIBRARY_SOURCES} ${TOIT_SYSTEM_SOURCES} "${TOIT_HOST}"
  VERBATIM)
add_custom_command(OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/application.snapshot"
  COMMAND "${TOIT_HOST}" compile -s -o application.snapshot
    --project-root "${TOIT_RP2040_PROJECT_ROOT}"
    --dependency-file application.dep --dependency-format ninja "${TOIT_RP2040_PROGRAM}"
  DEPFILE "${CMAKE_CURRENT_BINARY_DIR}/application.dep"
  DEPENDS "${TOIT_RP2040_PROGRAM}" ${TOIT_PACKAGE_INPUTS}
    ${TOIT_LIBRARY_SOURCES} "${TOIT_HOST}"
  VERBATIM)
add_custom_command(OUTPUT "${CMAKE_CURRENT_BINARY_DIR}/boot.S"
  COMMAND "${TOIT_HOST}" tool snapshot-to-image --format=binary -m32 -o boot.image boot.snapshot
  COMMAND "${TOIT_HOST}" tool snapshot-to-image --format=binary -m32 -o application.image application.snapshot
  COMMAND "${TOIT_HOST}" run --project-root "${TOIT_ROOT}/tools"
    "${TOIT_ROOT}/tools/rp2350/image-to-assembly.toit"
    -- boot.image boot.S application.image
  DEPENDS "${CMAKE_CURRENT_BINARY_DIR}/boot.snapshot" "${CMAKE_CURRENT_BINARY_DIR}/application.snapshot"
    "${TOIT_ROOT}/tools/rp2350/image-to-assembly.toit" "${TOIT_HOST}"
  VERBATIM)
option(TOIT_RP2040_ENVELOPE_BASE "Build a native base without embedded applications" OFF)
add_custom_target(system-snapshot DEPENDS "${CMAKE_CURRENT_BINARY_DIR}/boot.snapshot")
if (TOIT_RP2040_ENVELOPE_BASE)
  set(TOIT_RP2040_IMAGES "${TOIT_ROOT}/toolchains/rp2350/envelope-stub.S")
else()
  set(TOIT_RP2040_IMAGES "${CMAKE_CURRENT_BINARY_DIR}/boot.S")
endif()
add_executable(toit-rp2040 main.cc heap.c update.c
  "${TOIT_ROOT}/src/third_party/dartino/cmpctmalloc.c" "${TOIT_ROOT}/toolchains/rp2350/failure.cc"
  "${TOIT_RP2040_IMAGES}")
# Prevent compiler recognition of malloc+memset as a recursive calloc call.
set_source_files_properties(heap.c PROPERTIES COMPILE_OPTIONS "-fno-builtin")
set(TOIT_RP2040_TEST_FAULT "" CACHE STRING "Test-only native failure injection")
option(TOIT_RP2040_TEST_STORAGE_INTERRUPTION "Test-only partial flash operations and reset" OFF)
if (TOIT_RP2040_TEST_STORAGE_INTERRUPTION)
  if (TOIT_RP2040_ENVELOPE_BASE OR TOIT_RP2040_TEST_FAULT)
    message(FATAL_ERROR "Storage fault injection requires a dedicated, non-envelope test image")
  endif()
  target_sources(toit-rp2040 PRIVATE storage-interruption-test.cc)
  set_property(SOURCE "${TOIT_ROOT}/src/flash_registry_rp2040.cc" TARGET_DIRECTORY toit_vm
    APPEND PROPERTY COMPILE_DEFINITIONS TOIT_RP2040_TEST_STORAGE_INTERRUPTION=1)
endif()
if (TOIT_RP2040_TEST_FAULT)
  if (TOIT_RP2040_ENVELOPE_BASE)
    message(FATAL_ERROR "Fault injection must not be included in an envelope base")
  endif()
  if (NOT TOIT_RP2040_TEST_FAULT MATCHES "^(abort|exit|fatal|panic|hardfault|xip-fault|stack-overflow|watchdog-hang)$")
    message(FATAL_ERROR "Unknown TOIT_RP2040_TEST_FAULT")
  endif()
  # Reuse the RP2350 injector alongside the shared native failure handlers.
  # No injector or native fault command is present in ordinary builds.
  target_sources(toit-rp2040 PRIVATE "${TOIT_ROOT}/toolchains/rp2350/failure-test.cc")
  target_compile_definitions(toit-rp2040 PRIVATE TOIT_RP2350_TEST_FAULT="${TOIT_RP2040_TEST_FAULT}")
endif()
file(MAKE_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/app-link")
file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/app-link/memory_flash.incl"
  "MEMORY { FLASH(rx) : ORIGIN = 0x10020000, LENGTH = 0xf0000 }\n")
pico_add_linker_script_override_path(toit-rp2040 "${CMAKE_CURRENT_BINARY_DIR}/app-link")
target_include_directories(toit-rp2040 PRIVATE "${CMAKE_CURRENT_LIST_DIR}"
  "${TOIT_ROOT}/src" "${TOIT_ROOT}/include" "${PICO_SDK_PATH}/lib/mbedtls/include")
target_compile_definitions(toit-rp2040 PRIVATE
  PICO_CXX_DISABLE_ALLOCATION_OVERRIDES=1 PICO_MALLOC_PANIC=0 PICO_USE_MALLOC_MUTEX=0
  PICO_STACK_SIZE=0x1000 PICO_FLASH_ASSUME_CORE1_SAFE=1
  # Mix fresh oscillator samples for each output word supplied to mbedTLS.
  # The SDK default adds only one sample per PRNG output.
  PICO_RAND_ROSC_BIT_SAMPLE_COUNT=32
  PICO_PANIC_FUNCTION=toit_rp2350_panic PICO_PANIC_FUNCTION_DOES_NOT_RETURN=1
  MBEDTLS_CONFIG_FILE="${TOIT_ROOT}/mbedtls/include/rp2350_config.h"
  PICO_STDIO_USB_STDOUT_TIMEOUT_US=1000
  PICO_STDIO_USB_ENABLE_RESET_VIA_BAUD_RATE=0
  PICO_STDIO_USB_ENABLE_RESET_VIA_VENDOR_INTERFACE=0)
target_link_libraries(toit-rp2040 PRIVATE
  -Wl,--whole-archive toit_vm -Wl,--no-whole-archive
  mbedtls mbedx509 mbedcrypto pico_stdlib pico_rand pico_unique_id
  hardware_flash hardware_adc hardware_uart hardware_i2c hardware_spi hardware_dma hardware_pwm hardware_pio
  FreeRTOS-Kernel-Heap3)
pico_enable_stdio_usb(toit-rp2040 1)
pico_enable_stdio_uart(toit-rp2040 0)
pico_set_program_name(toit-rp2040 "Toit RP2040")
pico_add_extra_outputs(toit-rp2040)
