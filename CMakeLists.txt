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

cmake_minimum_required(VERSION 3.19.0)

project(toit)

# When using the downloadable sources there is no Git, so the version has
# to be given as argument.
set(TOIT_GIT_VERSION "$ENV{TOIT_GIT_VERSION}")
if ("${TOIT_GIT_VERSION}" STREQUAL "")
  include(tools/gitversion.cmake)
  # The Git version is only computed when cmake generates the Ninja files, but
  # that should be good enough.
  compute_git_version(TOIT_GIT_VERSION)
endif()

set(TOIT_SDK_SOURCE_DIR ${CMAKE_CURRENT_SOURCE_DIR})

if (DEFINED ENV{IDF_PATH})
  set(IDF_PATH "$ENV{IDF_PATH}")
else ()
  set(IDF_PATH "${CMAKE_CURRENT_SOURCE_DIR}/third_party/esp-idf")
endif()

set(CMAKE_INSTALL_MESSAGE LAZY)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# Put all binaries in /sdk/bin folder.
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/sdk/bin")
# Put all libraries in /lib folder.
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/lib")
set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/lib")

set(CMAKE_CXX_STANDARD 11)
set(CMAKE_CXX_EXTENSIONS ON)  # Needed so that `tzset` is available in esp-idf.

find_program(CCACHE_FOUND ccache)
if (CCACHE_FOUND)
  # On build-systems, it is recommended to set the CCACHE_BASEDIR environment
  # variable to the root of the checkout, so that different runs in different directories
  # can still take advantage of ccache.
  # Typically this is done by setting the environment variable for the build step.
  set(CMAKE_C_COMPILER_LAUNCHER   "${CCACHE_FOUND}")
  set(CMAKE_CXX_COMPILER_LAUNCHER "${CCACHE_FOUND}")
endif(CCACHE_FOUND)

if (${CMAKE_SYSTEM_NAME} MATCHES "Windows")
  set(TOIT_GENERIC_FLAGS "${TOIT_GENERIC_FLAGS} -static")
else()
  set(TOIT_GENERIC_FLAGS "${TOIT_GENERIC_FLAGS} '-fdebug-prefix-map=${PROJECT_SOURCE_DIR}=.'")
endif()

if (NOT ${ESP32_CHIP} MATCHES "esp32c3")
  set(TOIT_GENERIC_FLAGS "${TOIT_GENERIC_FLAGS} -Wno-unused-command-line-argument")
endif()

set(TOIT_GENERIC_FLAGS "${TOIT_GENERIC_FLAGS} -Wall -ffunction-sections -fdata-sections")

include_directories(
  "${IDF_PATH}/components/mbedtls/mbedtls/include"
  )

if (DEFINED USE_LWIP)
  set(LWIP_MBEDTLSDIR "../mbedtls")
  set(LWIP_DIR "third_party/esp-idf/components/lwip/lwip")
  set(LWIP_CONTRIB_DIR "${LWIP_DIR}/contrib")
  add_definitions(-DTOIT_USE_LWIP=1)
  include(${LWIP_DIR}/src/Filelists.cmake)
  include(${LWIP_DIR}/contrib/Filelists.cmake)
  include(${LWIP_DIR}/contrib/ports/unix/Filelists.cmake)

  # Put the lwip_on_linux directory in the include path.  This has our own
  # version of lwipopts.h, replacing the one in
  # third_party/lwip/contrib/ports/unix/lib.
  include_directories(src/third_party/lwip_on_linux)
  include_directories(third_party/esp-idf/components/lwip/lwip/src/include)
  include_directories(third_party/esp-idf/components/lwip/lwip/contrib/ports/unix/port/include)
endif()

# Set the output buffer size to 3700, reduced from 16k.  This is small enough
# that the allocation from MbedTLS is < 4k, 4033bytes to be precise.  We can
# also change the input buffer length, but this requires that all communication
# partners support the TLS protocol extension to tell them about this.
set(MBEDTLS_C_FLAGS "-DMBEDTLS_SSL_IN_CONTENT_LEN=4608 -DMBEDTLS_SSL_OUT_CONTENT_LEN=3700 -DMBEDTLS_PLATFORM_MEMORY=1")

set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} ${TOIT_GENERIC_FLAGS} ${TOIT_LWIP_C_FLAGS} ${MBEDTLS_C_FLAGS}")
set(CMAKE_C_FLAGS_DEBUG "${CMAKE_C_FLAGS_DEBUG} -DDEBUG")
set(CMAKE_C_FLAGS_RELEASE "${CMAKE_C_FLAGS_RELEASE} -DDEPLOY")
set(CMAKE_C_FLAGS_ASAN "${CMAKE_C_FLAGS_ASAN} -DDEBUG -DTOIT_ASAN")
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} ${TOIT_GENERIC_FLAGS} -fno-exceptions ${TOIT_LWIP_CXX_FLAGS} ${MBEDTLS_C_FLAGS}")
set(CMAKE_CXX_FLAGS_DEBUG "${CMAKE_CXX_FLAGS_DEBUG} -DDEBUG")
set(CMAKE_CXX_FLAGS_RELEASE "${CMAKE_CXX_FLAGS_RELEASE} -fno-rtti -DDEPLOY")
set(CMAKE_CXX_FLAGS_ASAN "${CMAKE_CXX_FLAGS_ASAN} -DDEBUG -DTOIT_ASAN")

if (${CMAKE_SYSTEM_NAME} MATCHES "Darwin")
    set(TOIT_LINK_GC_FLAGS "-Wl,-dead_strip")
    set(TOIT_LINK_GROUP_BEGIN_FLAGS "-Wl,-all_load")
else ()
    set(TOIT_LINK_GC_FLAGS "-Wl,--gc-sections")
    set(TOIT_LINK_GROUP_BEGIN_FLAGS "-Wl,--whole-archive")
    set(TOIT_LINK_GROUP_END_FLAGS "-Wl,--no-whole-archive")
endif()

if (NOT DEFINED TOIT_IS_CROSS)
  set(TOITC "$<TARGET_FILE:toit.compile>")
endif()

add_custom_target(
  build_toitlsp
  COMMAND make -C ${CMAKE_SOURCE_DIR} toitlsp
)

add_custom_target(
  build_version_file
  COMMAND echo ${TOIT_GIT_VERSION} > "${CMAKE_BINARY_DIR}/sdk/VERSION"
)

add_custom_target(
  build_snapshots
)

add_subdirectory(src)
add_subdirectory(tools)

enable_testing()
add_subdirectory(tests)

set(CMAKE_POLICY_DEFAULT_CMP0076 OLD)
# The 'ENABLE_TESTING' and 'ENABLE_PROGRAMS' variables (used by mbedtls) have no prefix. As
# such they might interfere with other libraries.
# Eventually, we need to import mbedtls differently.
set(ENABLE_TESTING CACHE BOOL OFF)
set(ENABLE_PROGRAMS CACHE BOOL OFF)
add_subdirectory(
  "${IDF_PATH}/components/mbedtls/mbedtls"
  "${CMAKE_BINARY_DIR}/mbedtls"
  EXCLUDE_FROM_ALL
  )

set(CMAKE_POLICY_DEFAULT_CMP0076 NEW)
