# Copyright (C) 2019 Toitware ApS.
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

set(CMAKE_SYSTEM_NAME Generic)

set(TOIT_SYSTEM_NAME esp32c3)

set(CMAKE_ASM_NASM_COMPILER riscv32-esp-elf-gcc)
set(CMAKE_C_COMPILER riscv32-esp-elf-gcc)
set(CMAKE_CXX_COMPILER riscv32-esp-elf-g++)

# Skip compiler checks.
set(CMAKE_C_COMPILER_WORKS 1)
set(CMAKE_CXX_COMPILER_WORKS 1)

set(CMAKE_C_FLAGS "-DESP32 -DDEPLOY=1 -D__FREERTOS__=1 -Wno-sign-compare" CACHE STRING "c flags")
set(CMAKE_CXX_FLAGS "${CMAKE_C_FLAGS} -DRAW=1 -fno-rtti" CACHE STRING "c++ flags")

set(CMAKE_C_FLAGS_DEBUG "-O0 -g" CACHE STRING "c Debug flags")
set(CMAKE_C_FLAGS_RELEASE "-Os" CACHE STRING "c Release flags")

set(CMAKE_CXX_FLAGS_DEBUG "-O0 -g" CACHE STRING "c++ Debug flags")
set(CMAKE_CXX_FLAGS_RELEASE "-Os" CACHE STRING "c++ Release flags")

set(TOIT_INTERPRETER_FLAGS "-fno-crossjumping -fno-tree-tail-merge" CACHE STRING "toit interpreter flags")

SET(CMAKE_ASM_FLAGS "${CFLAGS} -x assembler-with-cpp")

set(SKDCONFIG_INCLUDE_DIR "build/esp32c3/include" CACHE FILEPATH "Path to the sdkconfig.h include")

include_directories(
  $ENV{IDF_PATH}/components/app_update/include
  $ENV{IDF_PATH}/components/bootloader_support/include
  $ENV{IDF_PATH}/components/driver/esp32c3/include
  $ENV{IDF_PATH}/components/driver/include
  $ENV{IDF_PATH}/components/esp32c3/include
  $ENV{IDF_PATH}/components/esp_adc_cal/include
  $ENV{IDF_PATH}/components/esp_common/include
  $ENV{IDF_PATH}/components/esp_eth/include
  $ENV{IDF_PATH}/components/esp_event/include
  $ENV{IDF_PATH}/components/esp_hw_support/include
  $ENV{IDF_PATH}/components/esp_netif/include
  $ENV{IDF_PATH}/components/esp_ringbuf/include
  $ENV{IDF_PATH}/components/esp_rom/include
  $ENV{IDF_PATH}/components/esp_system/include
  $ENV{IDF_PATH}/components/esp_timer/include
  $ENV{IDF_PATH}/components/esp_wifi/include
  $ENV{IDF_PATH}/components/freertos/include
  $ENV{IDF_PATH}/components/freertos/include/esp_additions
  $ENV{IDF_PATH}/components/freertos/include/esp_additions/freertos
  $ENV{IDF_PATH}/components/freertos/port/xtensa/include
  $ENV{IDF_PATH}/components/hal/include
  $ENV{IDF_PATH}/components/hal/esp32c3/include
  $ENV{IDF_PATH}/components/heap/include
  $ENV{IDF_PATH}/components/log/include
  $ENV{IDF_PATH}/components/lwip/include/lwip
  $ENV{IDF_PATH}/components/lwip/lwip/src/include
  $ENV{IDF_PATH}/components/lwip/port/esp32/include
  $ENV{IDF_PATH}/components/lwip/include/apps
  $ENV{IDF_PATH}/components/lwip/include/apps/sntp
  $ENV{IDF_PATH}/components/mbedtls/mbedtls/include
  $ENV{IDF_PATH}/components/lwip/include/lwip/port
  $ENV{IDF_PATH}/components/newlib/platform_include
  $ENV{IDF_PATH}/components/nvs_flash/include
  $ENV{IDF_PATH}/components/spi_flash/include
  $ENV{IDF_PATH}/components/soc/esp32c3/include
  $ENV{IDF_PATH}/components/esp_hw_support/include/soc
  $ENV{IDF_PATH}/components/soc/include
  $ENV{IDF_PATH}/components/soc/soc/include
  $ENV{IDF_PATH}/components/soc/soc/esp32c3/include
  $ENV{IDF_PATH}/components/soc/src/esp32c3/include
  $ENV{IDF_PATH}/components/tcpip_adapter/include
  $ENV{IDF_PATH}/components/vfs/include
  $ENV{IDF_PATH}/components/ulp/include
  $ENV{IDF_PATH}/components/xtensa/esp32/include
  $ENV{IDF_PATH}/components/xtensa/include
  $ENV{IDF_PATH}/components/riscv/include
  $ENV{IDF_PATH}/components/bt/host/nimble/esp-hci/include
  $ENV{IDF_PATH}/components/bt/host/nimble/nimble/nimble/include
  $ENV{IDF_PATH}/components/bt/host/nimble/nimble/porting/nimble/include
  $ENV{IDF_PATH}/components/bt/host/nimble/nimble/porting/npl/freertos/include
  $ENV{IDF_PATH}/components/bt/host/nimble/nimble/nimble/host/include
  $ENV{IDF_PATH}/components/bt/host/nimble/nimble/nimble/host/util/include
  $ENV{IDF_PATH}/components/bt/include/esp32c3/include
  $ENV{IDF_PATH}/components/bt/host/nimble/nimble/nimble/host/services/gap/include
  $ENV{IDF_PATH}/components/bt/host/nimble/nimble/nimble/host/services/gatt/include
  ${SKDCONFIG_INCLUDE_DIR}
  )
