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

cmake_minimum_required(VERSION 3.20.0...4.0.1)

project(toit)

include(tools/toit.cmake)

set(CMAKE_COLOR_DIAGNOSTICS ON)

set(TOIT_IS_CROSS FALSE)
if ((NOT "${CMAKE_SYSTEM_NAME}" STREQUAL "${CMAKE_HOST_SYSTEM_NAME}") OR
    (NOT "${CMAKE_SYSTEM_PROCESSOR}" STREQUAL "${CMAKE_HOST_SYSTEM_PROCESSOR}"))
  # For '-m32' builds we don't enter here, as the system and processor are still the same. The
  # '-m32' is just a flag to the compiler.
  # This turns out to work out fine, as we can run the 32-bit executables anyway and don't
  # need a different host build to compile the snapshots.
  set(TOIT_IS_CROSS TRUE)
  # We are using the compiler from the host system, but we want to use the vessels
  # from the target system.
  set(TOIT_VESSELS_ROOT "${CMAKE_BINARY_DIR}/sdk/lib/toit/vessels")
endif()

set(TOIT_IS_EMBEDDED FALSE)
if ("${TOIT_SYSTEM_NAME}" MATCHES "esp32")
  set(TOIT_IS_EMBEDDED TRUE)
endif()

if (NOT DEFINED HOST_TOIT AND (NOT ${TOIT_IS_EMBEDDED}))
  set(HOST_TOIT "${CMAKE_BINARY_DIR}/sdk/bin/toit")
endif()

string(TIMESTAMP BUILD_DATE "%Y-%m-%dT%H:%M:%SZ" UTC)

# Tar balls are shipped with a version.cmake file.
include(version.cmake OPTIONAL)

# When using the downloadable sources there is no Git, so the version has
# to be given as argument.
if (NOT DEFINED TOIT_GIT_VERSION)
  set(TOIT_GIT_VERSION "$ENV{TOIT_GIT_VERSION}")
endif()
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

set(CMAKE_RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/sdk/bin")

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

option(ENABLE_LTO "Enable link-time optimization" OFF)

if (ENABLE_LTO AND
    "${CMAKE_SYSTEM_NAME}" STREQUAL "Linux" AND
    NOT ${TOIT_IS_CROSS})
  set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -flto=auto")
  set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -flto=auto")
  # GCC automatically performs link-time optimizations during linking if any
  # of the object files were compiled with -flto. However, it's safe to
  # explicitly enable LTO for the linker as well.
  set(CMAKE_EXE_LINKER_FLAGS "${CMAKE_EXE_LINKER_FLAGS} -flto")
  set(CMAKE_SHARED_LINKER_FLAGS "${CMAKE_SHARED_LINKER_FLAGS} -flto")
endif()

if ("${CMAKE_SYSTEM_NAME}" STREQUAL "Windows" OR "${CMAKE_SYSTEM_NAME}" STREQUAL "MSYS")
  set(TOIT_GENERIC_FLAGS "${TOIT_GENERIC_FLAGS} -static")
else()
  if (NOT ("${CMAKE_HOST_SYSTEM_NAME}" STREQUAL "Windows" OR "${CMAKE_HOST_SYSTEM_NAME}" STREQUAL "MSYS"))
    set(TOIT_GENERIC_FLAGS "${TOIT_GENERIC_FLAGS} '-fdebug-prefix-map=${PROJECT_SOURCE_DIR}=.'")
  endif()
endif()

set(TOIT_GENERIC_FLAGS "${TOIT_GENERIC_FLAGS} -Wall -ffunction-sections -fdata-sections")

include_directories(
  "${TOIT_SDK_SOURCE_DIR}/include"
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
# that the allocation from MbedTLS is < 4k, 4033bytes to be precise.  We set
# the input buffer length to 8k because some sites have very large certificates
# (eg Telegram, over 5100 bytes) and this is not something we can control.
# There are some protocol extensions for telling the other side about our buffer
# sizes, but they just cause the other side to fragment packets more aggressively.
# At this end we still have to reassemble the packets in and unfragmented form
# that fits in the buffer size below.
if ("${TOIT_SYSTEM_NAME}" MATCHES "esp32")
  # No need to set the flags, the same values are in the sdkconfig.
  # However, we need to include the esp32 config file to make sure that Toit and the compiled
  # MbedTLS sources agree on the defines.
  set(MBEDTLS_C_FLAGS "-DMBEDTLS_CONFIG_FILE=\\\"mbedtls/esp_config.h\\\"")
else()
  # For now we run with the full 16k size in the input buffer on host systems.
  # For devices we still run with a smaller buffer, which saves memory
  # pressure, but means the TLS connection often breaks after a while when the
  # counterpart makes the packets larger.  This ...IN_CONTENT_LEN define is
  # overriddden in sdkconfig files for devices.
  set(MBEDTLS_C_FLAGS "-DMBEDTLS_CONFIG_FILE=\\\"${CMAKE_SOURCE_DIR}/mbedtls/include/toit_config.h\\\"")
endif()

set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} ${TOIT_GENERIC_FLAGS} ${TOIT_LWIP_C_FLAGS} ${MBEDTLS_C_FLAGS}")
set(CMAKE_C_FLAGS_DEBUG "${CMAKE_C_FLAGS_DEBUG} -DTOIT_DEBUG")
set(CMAKE_C_FLAGS_RELEASE "${CMAKE_C_FLAGS_RELEASE} -DTOIT_DEPLOY")
set(CMAKE_C_FLAGS_ASAN "${CMAKE_C_FLAGS_ASAN} -DTOIT_DEBUG -DTOIT_ASAN")
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} ${TOIT_GENERIC_FLAGS} -fno-exceptions ${TOIT_LWIP_CXX_FLAGS} ${MBEDTLS_C_FLAGS}")
set(CMAKE_CXX_FLAGS_DEBUG "${CMAKE_CXX_FLAGS_DEBUG} -DTOIT_DEBUG")
set(CMAKE_CXX_FLAGS_RELEASE "${CMAKE_CXX_FLAGS_RELEASE} -fno-rtti -DTOIT_DEPLOY")
set(CMAKE_CXX_FLAGS_ASAN "${CMAKE_CXX_FLAGS_ASAN} -DTOIT_DEBUG -DTOIT_ASAN")

if ("${CMAKE_SYSTEM_NAME}" MATCHES "Darwin")
    set(TOIT_LINK_GC_FLAGS "-Wl,-dead_strip")
    set(TOIT_LINK_GROUP_BEGIN_FLAGS "-Wl,-all_load")
else ()
    set(TOIT_LINK_GC_FLAGS "-Wl,--gc-sections")
    set(TOIT_LINK_GROUP_BEGIN_FLAGS "-Wl,--whole-archive")
    set(TOIT_LINK_GROUP_END_FLAGS "-Wl,--no-whole-archive")
endif()

add_custom_target(
  build_version_file
  # It's important that there is no space after the version (before the '>'), as
  # Windows would add a space into the output otherwise.
  COMMAND echo ${TOIT_GIT_VERSION}> "${CMAKE_BINARY_DIR}/sdk/VERSION"
)

set(EXTERNAL_TOIT_LIBS)
include(tools/external.cmake)

add_subdirectory(src)
if ("${CMAKE_SYSTEM_NAME}" MATCHES "Linux")
  add_subdirectory(third_party/libgpiod)
endif()

if (NOT "${TOIT_SYSTEM_NAME}" MATCHES "esp32")
  add_subdirectory(tools)
  add_subdirectory(system/extensions/host)

  set(GO_ENV "$ENV{GO_BUILD_FLAGS}")
  separate_arguments(GO_ENV)
  list(APPEND GO_ENV GODEBUG=netdns=go "GOOS=${GOOS}" "GOARCH=${GOARCH}")

  set(GO_LINK_FLAGS "$ENV{GO_LINK_FLAGS} -X main.date=${BUILD_DATE} -X main.version=${TOIT_GIT_VERSION} -X main.sdkVersion=${TOIT_GIT_VERSION}")

  set(TOITPKG_BIN "${CMAKE_BINARY_DIR}/sdk/lib/toit/bin/toit.pkg${CMAKE_EXECUTABLE_SUFFIX}")

  add_custom_command(
    OUTPUT "${TOITPKG_BIN}"
    COMMAND "${CMAKE_COMMAND}" -E env ${GO_ENV} go build -ldflags "${GO_LINK_FLAGS}" -tags "netgo osusergo" -o "${TOITPKG_BIN}"
    WORKING_DIRECTORY ${TOIT_SDK_SOURCE_DIR}/tools/tpkg
  )

  add_custom_target(
    build_go_tools
    ALL
    DEPENDS "${TOITPKG_BIN}"
  )
  add_dependencies(build_tools build_go_tools)

  install(PROGRAMS "${TOITPKG_BIN}" DESTINATION lib/toit/bin)

  # Copy the lib folder to /usr/lib/toit/lib (recursively).
  install(DIRECTORY ${CMAKE_SOURCE_DIR}/lib/
    DESTINATION lib/toit/lib
    FILES_MATCHING PATTERN "*"
  )

  enable_testing()
  add_subdirectory(tests)

  add_subdirectory(examples)
  # External Toit packages and projects.
  add_subdirectory(external)

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
endif() # TOIT_SYSTEM_NAME != esp32
