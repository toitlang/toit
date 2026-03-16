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

# Toolchain file for the EC618 (Cortex-M3) target.
# The EC618 is a Cat.1bis LTE modem SoC by Eigencomm, used in modules
# like the Air780E.

set(CMAKE_SYSTEM_NAME "Generic" CACHE STRING "" FORCE)
set(CMAKE_SYSTEM_PROCESSOR "arm" CACHE STRING "" FORCE)
set(TOIT_SYSTEM_NAME "ec618" CACHE STRING "The Toit system name")

# We only build static libraries for this target — the final linking is done
# by the PLAT Makefile. Skip CMake's compiler linking test.
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)

set(FIND_LIBRARY_USE_LIB64_PATHS OFF)

# --- Compiler selection ---
# By default, use clang (consistent with other ARM toolchains in this project).
# Set EC618_USE_GCC=ON to use arm-none-eabi-gcc instead.
option(EC618_USE_GCC "Use arm-none-eabi-gcc instead of clang" OFF)

set(EC618_CPU_FLAGS "-mcpu=cortex-m3 -mthumb")

if (EC618_USE_GCC)
  set(CMAKE_C_COMPILER arm-none-eabi-gcc CACHE PATH "" FORCE)
  set(CMAKE_CXX_COMPILER arm-none-eabi-g++ CACHE PATH "" FORCE)
  set(CMAKE_ASM_COMPILER arm-none-eabi-gcc CACHE PATH "" FORCE)
else()
  set(CMAKE_C_COMPILER clang CACHE PATH "" FORCE)
  set(CMAKE_CXX_COMPILER clang++ CACHE PATH "" FORCE)
  set(CMAKE_ASM_COMPILER clang CACHE PATH "" FORCE)
  set(CMAKE_C_COMPILER_TARGET "arm-none-eabi" CACHE STRING "" FORCE)
  set(CMAKE_CXX_COMPILER_TARGET "arm-none-eabi" CACHE STRING "" FORCE)
  set(CMAKE_ASM_COMPILER_TARGET "arm-none-eabi" CACHE STRING "" FORCE)
endif()

# --- PLAT SDK paths ---
set(EC618_PLAT_DIR "${CMAKE_CURRENT_LIST_DIR}/../PLAT" CACHE PATH "Path to the EC618 PLAT SDK")
set(EC618_TARGET "ec618_0h00" CACHE STRING "EC618 board target")

set(PLAT_DEVICE "${EC618_PLAT_DIR}/device/target")
set(PLAT_CHIP "${EC618_PLAT_DIR}/driver/chip/ec618")
set(PLAT_BOARD "${PLAT_DEVICE}/board/${EC618_TARGET}")
set(PLAT_FREERTOS "${EC618_PLAT_DIR}/os/freertos")
set(PLAT_MIDDLEWARE "${EC618_PLAT_DIR}/middleware")
set(PLAT_PREBUILD "${EC618_PLAT_DIR}/prebuild")

# --- Compiler flags ---
set(EC618_COMMON_FLAGS
  "${EC618_CPU_FLAGS} \
  -nostartfiles \
  -mapcs-frame \
  -ffunction-sections \
  -fdata-sections \
  -fno-isolate-erroneous-paths-dereference \
  -freorder-blocks-algorithm=stc \
  -gdwarf-2"
)

if (NOT EC618_USE_GCC)
  # Clang doesn't support all GCC flags; adjust as needed.
  set(EC618_COMMON_FLAGS
    "${EC618_CPU_FLAGS} \
    -nostartfiles \
    -ffunction-sections \
    -fdata-sections \
    -gdwarf-2"
  )
endif()

set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} ${EC618_COMMON_FLAGS}" CACHE STRING "" FORCE)
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} ${EC618_COMMON_FLAGS}" CACHE STRING "" FORCE)

if (EC618_USE_GCC)
  set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -specs=nano.specs" CACHE STRING "" FORCE)
  set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -specs=nano.specs" CACHE STRING "" FORCE)
  set(CMAKE_ASM_FLAGS "${CMAKE_ASM_FLAGS} ${EC618_CPU_FLAGS} --apcs=interwork -D__MICROLIB" CACHE STRING "" FORCE)
else()
  set(CMAKE_ASM_FLAGS "${CMAKE_ASM_FLAGS} ${EC618_CPU_FLAGS}" CACHE STRING "" FORCE)
endif()

set(CMAKE_C_FLAGS_RELEASE "-Os" CACHE STRING "" FORCE)
set(CMAKE_CXX_FLAGS_RELEASE "-Os" CACHE STRING "" FORCE)

# --- Include directories from the PLAT SDK ---
include_directories(SYSTEM
  "${PLAT_BOARD}/common/inc"
  "${PLAT_BOARD}/ap/inc"
  "${PLAT_BOARD}/ap/apps/toit/inc"
  "${PLAT_CHIP}/ap/inc"
  "${PLAT_CHIP}/ap/inc_cmsis"
  "${PLAT_DEVICE}/include"
  "${PLAT_FREERTOS}/inc"
  "${PLAT_FREERTOS}/CMSIS/ap/inc"
  "${PLAT_FREERTOS}/CMSIS/common/inc"
  "${PLAT_FREERTOS}/portable/gcc"
  "${PLAT_FREERTOS}/portable/mem/cmpctmalloc"
  "${PLAT_MIDDLEWARE}/developed/qcapi/psapi/inc"
  "${PLAT_MIDDLEWARE}/developed/qcapi/apimsg/inc"
  "${PLAT_MIDDLEWARE}/thirdparty/lwip/src/include"
  "${PLAT_MIDDLEWARE}/thirdparty/lwip/src/include/lwip"
  "${PLAT_PREBUILD}/PS/inc"
)

# --- Compile definitions ---
add_definitions(
  -D__EC618
  -DCHIP_EC618
  -DCORE_IS_AP
  -D__FREERTOS__
  -DSDK_REL_BUILD
  -DconfigUSE_NEWLIB_REENTRANT=1
  -DARM_MATH_CM3
  -DCONFIG_TOIT_ENABLE_IP
  -DCONFIG_TOIT_CRYPTO
  -DCONFIG_TOIT_FONT
  -DCONFIG_TOIT_BITMAP
  -DCONFIG_TOIT_BIT_DISPLAY
  -DCONFIG_TOIT_BYTE_DISPLAY
)
