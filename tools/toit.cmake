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

# This file serves as normal cmake include, as well as a cmake-script, run with
# `cmake -P`.
# In the latter case the `EXECUTING_SCRIPT` variable is defined, and we only
# process the command that we should execute.

option(TOIT_PKG_AUTO_SYNC "Automatically sync packages when building" ON)

set(TOIT_DOWNLOAD_PACKAGE_SCRIPT "${CMAKE_CURRENT_LIST_DIR}/toit.cmake")
if (DEFINED EXECUTING_SCRIPT)
  if ("${SCRIPT_COMMAND}" STREQUAL "install_packages")
    if (NOT DEFINED TOIT_PROJECT)
      message(FATAL_ERROR "Missing TOIT_PROJECT")
    endif()
    if (NOT DEFINED HOST_TOIT)
      message(FATAL_ERROR "Missing HOST_TOIT")
    endif()

    execute_process(
      COMMAND "${HOST_TOIT}" pkg install --no-auto-sync "--project-root=${TOIT_PROJECT}"
      COMMAND_ERROR_IS_FATAL ANY
    )
    set(PACKAGE_TIMESTAMP "${TOIT_PROJECT}/.packages/package-timestamp")
    file(REMOVE "${PACKAGE_TIMESTAMP}")
    if (EXISTS "${TOIT_PROJECT}/package.yaml")
      file(APPEND "${PACKAGE_TIMESTAMP}" ${TOIT_PROJECT}/package.yaml)
    endif()
    if (EXISTS "${TOIT_PROJECT}/package.lock")
      file(APPEND "${PACKAGE_TIMESTAMP}" ${TOIT_PROJECT}/package.lock)
    endif()
  else()
    message(FATAL_ERROR "Unknown script command ${SCRIPT_COMMAND}")
  endif()

  # End the execution of this file.
  return()
endif()

# Creates a custom command to build ${TARGET} with correct dependencies.
function(ADD_TOIT_SNAPSHOT SOURCE TARGET DEP_FILE ENV)
  if (NOT DEFINED HOST_TOIT)
    set(HOST_TOIT "$ENV{HOST_TOIT}")
    if ("${HOST_TOIT}" STREQUAL "")
      # HOST_TOIT is normally set to the toit executable.
      # However, for cross-compilation the compiler must be provided manually.
      message(FATAL_ERROR "HOST_TOIT not provided")
    endif()
  endif()
  if(POLICY CMP0116)
    cmake_policy(SET CMP0116 NEW)
  endif()
  add_custom_command(
    OUTPUT "${TARGET}"
    DEPFILE ${DEP_FILE}
    DEPENDS "${HOST_TOIT}" download_packages "${SOURCE}"
    COMMAND ${CMAKE_COMMAND} -E env ${ENV} ASAN_OPTIONS=detect_leaks=false
      "${HOST_TOIT}" compile
      --dependency-file "${DEP_FILE}"
      --dependency-format ninja
      -O2
      --snapshot
      -o "${TARGET}"
      "${SOURCE}"
  )
endfunction(ADD_TOIT_SNAPSHOT)

# Creates a custom command to build ${TARGET} with correct dependencies.
function(ADD_TOIT_EXE SOURCE TARGET DEP_FILE ENV)
  if (NOT DEFINED HOST_TOIT)
    set(HOST_TOIT "$ENV{HOST_TOIT}")
    if ("${HOST_TOIT}" STREQUAL "")
      # HOST_TOIT is normally set to the toit executable.
      # However, for cross-compilation the compiler must be provided manually.
      message(FATAL_ERROR "HOST_TOIT not provided")
    endif()
  endif()
  if(POLICY CMP0116)
    cmake_policy(SET CMP0116 NEW)
  endif()
  set(VESSELS_FLAG)
  if (TOIT_VESSELS_ROOT)
    set(VESSELS_FLAG --vessels-root "${TOIT_VESSELS_ROOT}")
  endif()
  add_custom_command(
    OUTPUT "${TARGET}"
    DEPFILE ${DEP_FILE}
    DEPENDS "${HOST_TOIT}" download_packages "${SOURCE}"
    COMMAND ${CMAKE_COMMAND} -E env ${ENV} ASAN_OPTIONS=detect_leaks=false
      "${HOST_TOIT}" compile
      --dependency-file "${DEP_FILE}"
      --dependency-format ninja ${VESSELS_FLAG}
      -O2
      -o "${TARGET}"
      "${SOURCE}"
  )
endfunction(ADD_TOIT_EXE)

macro(toit_project NAME PATH)
  if (EXISTS "${PATH}/package.yaml" OR EXISTS "${PATH}/package.lock")
    set(PACKAGE_FILES)
    if (EXISTS "${PATH}/package.yaml")
      list(APPEND PACKAGE_FILES "${PATH}/package.yaml")
    endif()
    if (EXISTS "${PATH}/package.lock")
      list(APPEND PACKAGE_FILES "${PATH}/package.lock")
    endif()
    if (NOT DEFINED HOST_TOIT)
      set(HOST_TOIT "$ENV{HOST_TOIT}")
      if ("${HOST_TOIT}" STREQUAL "")
        # HOST_TOIT is normally set to the toit executable.
        # However, for cross-compilation the compiler must be provided manually.
        message(FATAL_ERROR "HOST_TOIT not provided")
      endif()
    endif()

    if (NOT TARGET download_packages)
      add_custom_target(
        download_packages
      )
      add_custom_target(
        sync_packages
        COMMAND "${HOST_TOIT}" pkg sync
        DEPENDS "${HOST_TOIT}"
      )
    endif()

    add_custom_target(sync-${NAME}-packages)

    if (${TOIT_PKG_AUTO_SYNC})
      add_dependencies(sync-${NAME}-packages sync_packages)
    endif()

    set(PACKAGE_TIMESTAMP "${PATH}/.packages/package-timestamp")
    add_custom_command(
      OUTPUT "${PACKAGE_TIMESTAMP}"
      COMMAND "${CMAKE_COMMAND}"
          -DEXECUTING_SCRIPT=true
          -DSCRIPT_COMMAND=install_packages
          "-DTOIT_PROJECT=${PATH}"
          "-DHOST_TOIT=${HOST_TOIT}"
          -P "${TOIT_DOWNLOAD_PACKAGE_SCRIPT}"
      DEPENDS "${HOST_TOIT}" ${PACKAGE_FILES} sync-${NAME}-packages
    )

    add_custom_target(
      install-${NAME}-packages
      DEPENDS "${PACKAGE_TIMESTAMP}"
    )

    add_dependencies(download_packages install-${NAME}-packages)
  endif()

endmacro()
