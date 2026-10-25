# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
cmake_minimum_required(VERSION 3.20.0)
find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(toit_ble_native_tests C CXX)
get_filename_component(TOIT_ROOT "${CMAKE_CURRENT_LIST_DIR}/../../../.." ABSOLUTE)
target_compile_definitions(app PRIVATE TOIT_ZEPHYR)
target_include_directories(app PRIVATE "${TOIT_ROOT}/src/resources")
target_include_directories(app PRIVATE "${ZEPHYR_BASE}/subsys/bluetooth/host")
target_sources(app PRIVATE main.cc
  "${TOIT_ROOT}/src/resources/ble_zephyr_server.cc"
  "${TOIT_ROOT}/toolchains/zephyr/bluetooth_crypto.c")
