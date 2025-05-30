# Copyright (C) 2022 Toitware ApS.
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

file(GLOB toit_compiler_SRC
    "*.h"
    "*.cc"
    "lsp/*.h"
    "lsp/*.cc"
    "optimizations/*.h"
    "optimizations/*.cc"
    "propagation/*.h"
    "propagation/*.cc"
)
list(FILTER toit_compiler_SRC EXCLUDE REGEX "/toitc.cc$")

add_subdirectory(third_party/libyaml EXCLUDE_FROM_ALL)
add_subdirectory(third_party/semver EXCLUDE_FROM_ALL)

add_library(
  toit_compiler
  ${toit_compiler_SRC}
  )

set_source_files_properties(propagation/type_database.cc PROPERTIES COMPILE_OPTIONS "-O3")
set_source_files_properties(propagation/type_propagator.cc PROPERTIES COMPILE_OPTIONS "-O3")
set_source_files_properties(propagation/type_set.cc PROPERTIES COMPILE_OPTIONS "-O3")
set_source_files_properties(propagation/type_stack.cc PROPERTIES COMPILE_OPTIONS "-O3")

if (DEFINED ENV{TOIT_OPTIMIZATION_OVERRIDE})
  # Use the optimization level from the environment and pass it in as define.
  message("OVERRIDING OPTIMIZATION LEVEL")
  target_compile_definitions(toit_compiler PRIVATE TOIT_OPTIMIZATION_OVERRIDE=$ENV{TOIT_OPTIMIZATION_OVERRIDE})
endif()
if (DEFINED ENV{TOIT_ASSERT_OVERRIDE})
  # Use the assert setting from the environment and pass it in as define.
  message("OVERRIDING ENABLE-ASSERT")
  target_compile_definitions(toit_compiler PRIVATE TOIT_ASSERT_OVERRIDE=$ENV{TOIT_ASSERT_OVERRIDE})
endif()

if (${TOIT_IS_CROSS})
  set(TOIT_COMPILER_STATIC -static)
endif()

target_link_libraries(
  toit_compiler
  ${TOIT_COMPILER_STATIC}
  ${YAML_STATIC_LIB_NAME}
  ${SEMVER_STATIC_LIB_NAME}
  ${UTF_8_MANIFEST_LIB}
  )

add_executable(
  toit.compile
  toitc.cc
  )
set_target_properties(toit.compile PROPERTIES RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/sdk/lib/toit/bin")

add_dependencies(build_tools toit.compile)

target_link_libraries(toit.compile -static-libstdc++)

if ("${CMAKE_SYSTEM_NAME}" MATCHES "MSYS")
  set(TOIT_WINDOWS_LIBS ws2_32 rpcrt4)
elseif ("${CMAKE_SYSTEM_NAME}" MATCHES "Windows")
  set(TOIT_WINDOWS_LIBS rpcrt4)
else()
  set(TOIT_WINDOWS_LIBS )
endif()

target_link_libraries(
  toit.compile
  ${TOIT_COMPILER_STATIC}
  toit_compiler
  toit_core
  mbedtls
  ${TOIT_WINDOWS_LIBS}
  pthread
  ${CMAKE_DL_LIBS}
  toit_porting
  )

set(TOIT_LIB_DIR "${CMAKE_BINARY_DIR}/sdk/lib/toit/lib")

add_custom_command(
  OUTPUT ${TOIT_LIB_DIR}
  COMMAND ${CMAKE_COMMAND} -E create_symlink ${TOIT_SDK_SOURCE_DIR}/lib ${TOIT_LIB_DIR}
  VERBATIM
)

add_custom_target(
  generate-lib-symlink
  DEPENDS ${TOIT_LIB_DIR}
  )

add_dependencies(toit.compile generate-lib-symlink)
