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

set(EXTERNAL_TOIT_LIB_DIRS "$ENV{EXTERNAL_TOIT_LIB_DIRS}" CACHE STRING "List of directories to search for external toit libraries")

SET(TOIT_INCLUDE_DIR "${CMAKE_SOURCE_DIR}/include")

if (NOT DEFINED ESP_PLATFORM)
  function(_toit_external_register)
    set(options WHOLE_ARCHIVE) # Ignored. We always use 'OBJECT' libraries.
    set(single_value NAME DIR)
    set(multi_value SRCS PRIV_INCLUDE_DIRS REQUIRES)
    cmake_parse_arguments(REG "${options}" "${single_value}" "${multi_value}" ${ARGN})

    if (NOT DEFINED REG_NAME)
      message(FATAL_ERROR "toit_external_register: NAME is required")
    endif()
    set(sources)
    foreach(src ${REG_SRCS})
      cmake_path(ABSOLUTE_PATH src BASE_DIRECTORY ${REG_DIR})
      list(APPEND sources ${src})
    endforeach()
    # We use object libraries so we don't need the whole-archive flags.
    add_library(${REG_NAME} OBJECT ${sources})
    target_include_directories(${REG_NAME} PUBLIC ${TOIT_INCLUDE_DIR})
    if (DEFINED REG_PRIV_INCLUDE_DIRS)
      target_include_directories(${REG_NAME} PRIVATE ${REG_PRIV_INCLUDE_DIRS})
    endif()
    set(TMP_LIBS ${EXTERNAL_TOIT_LIBS})
    list(APPEND TMP_LIBS ${REG_NAME})
    set(EXTERNAL_TOIT_LIBS ${TMP_LIBS} PARENT_SCOPE)
  endfunction()

  macro(toit_external_register)
    # The lib name is the last segment of the directory.
    get_filename_component(_lib_name ${CMAKE_CURRENT_LIST_DIR} NAME)
    get_filename_component(_lib_dir ${CMAKE_CURRENT_LIST_DIR} ABSOLUTE)
    _toit_external_register(NAME "${_lib_name}" DIR "${_lib_dir}" ${ARGV})
  endmacro()

  # Libraries that should be used both by the ESP build and as external library need
  # to be registered with idf_component_register.
  macro(idf_component_register)
    toit_external_register(${ARGV})
  endmacro()
endif()

# For each of the external libs load the cmake file.
foreach(container_dir IN LISTS EXTERNAL_TOIT_LIB_DIRS)
  file(GLOB external_lib_dirs ${container_dir}/*)
  foreach(dir ${external_lib_dirs})
    # A potential lib must be a directory.
    if (NOT IS_DIRECTORY ${dir})
      continue()
    endif()
    file(GLOB cmake_files "${dir}/toit.cmake")
    foreach(cmake_file IN LISTS cmake_files)
      include(${cmake_file})
    endforeach()
  endforeach()
endforeach()
