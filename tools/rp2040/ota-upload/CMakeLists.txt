# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by the LGPL-2.1 license in LICENSE.

cmake_minimum_required(VERSION 3.16)
project(toit-rp2040-ota-upload LANGUAGES CXX)

add_executable(rp2040-ota-upload ota_upload.cc)
set_target_properties(
  rp2040-ota-upload PROPERTIES
  CXX_STANDARD 11
  CXX_STANDARD_REQUIRED YES
  CXX_EXTENSIONS NO
)

if(MSVC)
  target_compile_options(rp2040-ota-upload PRIVATE /W4)
else()
  target_compile_options(rp2040-ota-upload PRIVATE -Wall -Wextra -Werror)
endif()

# Keep GNU runtime libraries out of the distributable. Linux retains its
# system libc and loader; MinGW retains only Windows system DLL imports.
if(CMAKE_CXX_COMPILER_ID STREQUAL "GNU")
  if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
    target_link_options(rp2040-ota-upload PRIVATE -static-libstdc++ -static-libgcc)
  elseif(WIN32)
    target_link_options(rp2040-ota-upload PRIVATE -static)
  endif()
endif()

install(TARGETS rp2040-ota-upload RUNTIME DESTINATION bin)

include(CTest)
if(BUILD_TESTING AND UNIX)
  find_package(Python3 COMPONENTS Interpreter)
  if(Python3_FOUND)
    add_test(NAME rp2040-uploader-pty COMMAND "${Python3_EXECUTABLE}"
      "${CMAKE_CURRENT_SOURCE_DIR}/test_upload.py" "$<TARGET_FILE:rp2040-ota-upload>")
    set_tests_properties(rp2040-uploader-pty PROPERTIES TIMEOUT 120)
  endif()
endif()
