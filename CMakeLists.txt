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

cmake_minimum_required(VERSION 3.13.3)

project(toit)

set(CMAKE_INSTALL_MESSAGE LAZY)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# Put all binaries in /bin folder.
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin")
# Put all libraries in /lib folder.
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/lib")
set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/lib")

set(CMAKE_CXX_STANDARD 11)
set(CMAKE_CXX_EXTENSIONS ON)  # Needed so that `tzset` is available in esp-idf.

find_program(CCACHE_FOUND ccache)
if (CCACHE_FOUND)
  set_property(GLOBAL PROPERTY RULE_LAUNCH_COMPILE "CCACHE_BASEDIR=${PROJECT_SOURCE_DIR} ${CCACHE_FOUND}")
  set_property(GLOBAL PROPERTY RULE_LAUNCH_LINK "CCACHE_BASEDIR=${PROJECT_SOURCE_DIR} ${CCACHE_FOUND}")
endif(CCACHE_FOUND)

set(TOIT_GENERIC_FLAGS "'-fdebug-prefix-map=${PROJECT_SOURCE_DIR}=.' -Wall -Werror -ffunction-sections -fdata-sections -Wno-unused-command-line-argument -Wno-error=string-concatenation")

include_directories(
  "$ENV{IDF_PATH}/components/mbedtls/mbedtls/include"
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

add_custom_target(
  build_toitlsp
  COMMAND make -C ${CMAKE_SOURCE_DIR} toitlsp
)

set(CMAKE_POLICY_DEFAULT_CMP0076 OLD)
add_subdirectory(
  "$ENV{IDF_PATH}/components/mbedtls/mbedtls"
  "${CMAKE_RUNTIME_OUTPUT_DIRECTORY}/mbedtls"
  )

set(CMAKE_POLICY_DEFAULT_CMP0076 NEW)
add_subdirectory(src)
add_subdirectory(tests)
