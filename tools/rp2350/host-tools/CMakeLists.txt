# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by the LGPL-2.1 license in LICENSE.

cmake_minimum_required(VERSION 3.20)
project(toit_rp2350_host_tools LANGUAGES C CXX)
include(FetchContent)
if(POLICY CMP0135)
  cmake_policy(SET CMP0135 NEW)
endif()

get_filename_component(TOIT_ROOT "${CMAKE_CURRENT_LIST_DIR}/../../.." ABSOLUTE)
set(PICO_SDK_PATH "${TOIT_ROOT}/third_party/pico-sdk" CACHE PATH "Pico SDK headers")
set(PICO_MBEDTLS_PATH "${TOIT_ROOT}/third_party/esp-idf/components/mbedtls/mbedtls"
    CACHE PATH "mbedTLS sources")
if(NOT EXISTS "${PICO_SDK_PATH}/pico_sdk_version.cmake" OR
   NOT EXISTS "${PICO_MBEDTLS_PATH}/library/aes.c")
  message(FATAL_ERROR "Initialize third_party/pico-sdk and ESP-IDF's mbedTLS submodule first")
endif()

# Keep libusb replaceable without relinking picotool. No system libusb or udev
# installation is required, including when cross-compiling an SDK.
set(LIBUSB_BUILD_SHARED_LIBS ON CACHE BOOL "" FORCE)
set(LIBUSB_ENABLE_UDEV OFF CACHE BOOL "" FORCE)
set(LIBUSB_INSTALL_TARGETS OFF CACHE BOOL "" FORCE)
set(LIBUSB_BUILD_TESTING OFF CACHE BOOL "" FORCE)
set(LIBUSB_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
FetchContent_Declare(rp2350_libusb
  URL https://github.com/libusb/libusb-cmake/archive/c8477c10ac2ac6b1718d4d498e102b9f18b776f5.tar.gz
  URL_HASH SHA256=7ae0070edc1b9595169531220a94f6f95ce4678694e073e5589149e06dc1e58f
  SOURCE_SUBDIR unused)
FetchContent_Declare(rp2350_picotool
  URL https://github.com/raspberrypi/picotool/archive/2041936441b48a3cc53ae3da9e805229fe8f4e18.tar.gz
  URL_HASH SHA256=7b22c6d402a41355c7536884e380fac8085cedcd2054d680e71a335499fb9f57
  SOURCE_SUBDIR unused)
FetchContent_MakeAvailable(rp2350_libusb rp2350_picotool)
add_subdirectory("${rp2350_libusb_SOURCE_DIR}" "${rp2350_libusb_BINARY_DIR}" EXCLUDE_FROM_ALL)
if(UNIX)
  set_target_properties(usb-1.0 PROPERTIES VERSION 0 SOVERSION 0)
endif()

set(LIBUSB_INCLUDE_DIR "${rp2350_libusb_SOURCE_DIR}/libusb/libusb")
# Avoid exposing the private library target in picotool's upstream export set.
set(LIBUSB_LIBRARIES "$<TARGET_LINKER_FILE:usb-1.0>")
set(PICOTOOL_NO_LIBUSB OFF CACHE BOOL "" FORCE)
set(PICOTOOL_LIBUSB_ALLOW_DLL ON CACHE BOOL "" FORCE)
set(PICOTOOL_CODE_OTP 0 CACHE STRING "" FORCE)
set(USE_PRECOMPILED ON CACHE BOOL "" FORCE)
add_subdirectory("${rp2350_picotool_SOURCE_DIR}" "${rp2350_picotool_BINARY_DIR}" EXCLUDE_FROM_ALL)
add_dependencies(picotool usb-1.0)
set(BUILD_TESTING OFF CACHE BOOL "" FORCE)
add_subdirectory("${TOIT_ROOT}/tools/rp2350/ota-upload" ota-upload EXCLUDE_FROM_ALL)

if(APPLE)
  set_target_properties(picotool PROPERTIES INSTALL_RPATH "@loader_path")
elseif(UNIX)
  set_target_properties(picotool PROPERTIES INSTALL_RPATH "$ORIGIN")
endif()
if(CMAKE_CXX_COMPILER_ID STREQUAL "GNU")
  target_link_options(picotool PRIVATE -static-libstdc++ -static-libgcc)
  target_link_options(usb-1.0 PRIVATE -static-libgcc)
  if(MINGW)
    # libusb is linked via its explicit import library; -static only changes
    # the search for compiler runtime libraries (including winpthreads).
    target_link_options(picotool PRIVATE -static)
    target_link_options(usb-1.0 PRIVATE -static)
  endif()
endif()
add_custom_target(rp2350-host-tools ALL DEPENDS picotool ota-upload usb-1.0)
install(TARGETS picotool ota-upload usb-1.0
  RUNTIME DESTINATION lib/toit/bin
  LIBRARY DESTINATION lib/toit/bin
  ARCHIVE DESTINATION lib/toit/rp2350)

set(notices lib/toit/rp2350/licenses)
install(FILES "${rp2350_libusb_SOURCE_DIR}/libusb/COPYING" DESTINATION ${notices} RENAME libusb.txt)
install(FILES "${rp2350_libusb_SOURCE_DIR}/LICENSE" DESTINATION ${notices} RENAME libusb-cmake.txt)
install(FILES "${rp2350_picotool_SOURCE_DIR}/LICENSE.TXT" DESTINATION ${notices} RENAME picotool.txt)
install(FILES "${rp2350_picotool_SOURCE_DIR}/clipp/LICENSE" DESTINATION ${notices} RENAME clipp.txt)
install(FILES "${rp2350_picotool_SOURCE_DIR}/lib/littlefs/LICENSE.md" DESTINATION ${notices} RENAME littlefs.txt)
install(FILES "${rp2350_picotool_SOURCE_DIR}/lib/nlohmann_json/LICENSE.MIT" DESTINATION ${notices} RENAME nlohmann-json.txt)
install(FILES "${rp2350_picotool_SOURCE_DIR}/lib/oofatfs/LICENSE" DESTINATION ${notices} RENAME oofatfs.txt)
# Picotool vendors whereami without its separate upstream license file.
install(FILES whereami.LICENSE DESTINATION ${notices} RENAME whereami.txt)
install(FILES "${PICO_SDK_PATH}/LICENSE.TXT" DESTINATION ${notices} RENAME pico-sdk.txt)
install(FILES "${PICO_MBEDTLS_PATH}/LICENSE" DESTINATION ${notices} RENAME mbedtls.txt)
install(FILES "${rp2350_picotool_SOURCE_DIR}/udev/60-picotool.rules" DESTINATION lib/toit/rp2350)
install(FILES README.md DESTINATION lib/toit/rp2350)

# Ship the exact LGPL source, including its portable CMake recipe. It can be
# rebuilt independently to replace the adjacent shared library.
execute_process(COMMAND "${CMAKE_COMMAND}" -E tar czf
  "${CMAKE_CURRENT_BINARY_DIR}/libusb-source.tar.gz" --format=gnutar
  CMakeLists.txt LICENSE README.md config.h.in libusb examples tests
  WORKING_DIRECTORY "${rp2350_libusb_SOURCE_DIR}"
  COMMAND_ERROR_IS_FATAL ANY)
install(FILES "${CMAKE_CURRENT_BINARY_DIR}/libusb-source.tar.gz" DESTINATION lib/toit/rp2350)
