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

if (NOT "${TOIT_SYSTEM_NAME}" MATCHES "esp32")
  add_custom_target(build_tools)
  add_subdirectory(compiler)
endif()

# Use D flags to switch tools to deterministic mode (no timestamps etc.)
# This is part of getting a reproducible build.  This flag is not available
# in the 'ar' used on macOS.
if (NOT ("${CMAKE_SYSTEM_NAME}" MATCHES "Darwin"))
  set(CMAKE_C_ARCHIVE_CREATE "<CMAKE_AR> qcD <TARGET> <LINK_FLAGS> <OBJECTS>")
  set(CMAKE_CXX_ARCHIVE_CREATE "<CMAKE_AR> qcD <TARGET> <LINK_FLAGS> <OBJECTS>")
  set(CMAKE_C_ARCHIVE_APPEND "<CMAKE_AR> qD <TARGET> <LINK_FLAGS> <OBJECTS>")
  set(CMAKE_CXX_ARCHIVE_APPEND "<CMAKE_AR> qD <TARGET> <LINK_FLAGS> <OBJECTS>")
  set(CMAKE_C_ARCHIVE_FINISH "<CMAKE_RANLIB> -D <TARGET>")
  set(CMAKE_CXX_ARCHIVE_FINISH "<CMAKE_RANLIB> -D <TARGET>")
endif()

file(GLOB toit_core_SRC
  "*.h"
  "*.c"
  "*.cc"
  )

# Sources that are only needed to run a program.
file(GLOB run_SRC
  "run.cc"
)

# Exclude files with a main(), and files that are not used in the compiler.
list(FILTER toit_core_SRC EXCLUDE REGEX "/(toit|toit_run|toit_run_image|vessel|vm|objects_runtime).cc$")
list(REMOVE_ITEM toit_core_SRC ${run_SRC})

# Files that are used in the VM, but not in the compiler.
file(GLOB toit_vm_runtime_SRC
  "vm.h"
  "vm.cc"
  "objects_runtime.cc"
  )

file(GLOB toit_resources_SRC
  "resources/*.h"
  "resources/*.cc"
  "resources/*.c"
  )

if ("${CMAKE_SYSTEM_NAME}" MATCHES "Darwin")
  list(APPEND toit_resources_SRC "resources/ble_darwin.mm")
endif()

file(GLOB toit_event_sources_SRC
  "event_sources/*.h"
  "event_sources/*.cc"
  )

file(GLOB lwip_on_linux_sources_SRC
  "third_party/lwip_on_linux/*.h"
  "third_party/lwip_on_linux/*.cc"
  )

file(GLOB gc_sources_SRC
  "third_party/dartino/object_memory.h"
  "third_party/dartino/object_memory.cc"
  "third_party/dartino/object_memory_copying.cc"
  "third_party/dartino/object_memory_mark_sweep.cc"
  "third_party/dartino/gc_metadata.h"
  "third_party/dartino/gc_metadata.cc"
  "third_party/dartino/two_space_heap.h"
  "third_party/dartino/two_space_heap.cc"
  )

file(GLOB porting_sources_SRC
  "ports/*.h"
  "ports/*.cc"
  )

set(toit_vm_SRC ${toit_vm_runtime_SRC} ${toit_resources_SRC} ${toit_event_sources_SRC}
                ${lwip_on_linux_sources_SRC} ${gc_sources_SRC})

add_library(
  toit_core
  ${toit_core_SRC}
  )

add_library(
  toit_vm
  ${toit_vm_SRC}
  ${toit_core_SRC}
  )

add_library(
  toit_porting
  ${porting_sources_SRC}
  )

if (DEFINED ENV{TOIT_CHECK_PROPAGATED_TYPES})
  set(TOIT_INTERPRETER_FLAGS "${TOIT_INTERPRETER_FLAGS};-DTOIT_CHECK_PROPAGATED_TYPES")
endif()

set_source_files_properties(interpreter_core.cc PROPERTIES COMPILE_OPTIONS "-O3;$ENV{LOCAL_INTERPRETER_CXXFLAGS}")
set_source_files_properties(interpreter_run.cc PROPERTIES COMPILE_OPTIONS "-O3;${TOIT_INTERPRETER_FLAGS};$ENV{LOCAL_INTERPRETER_CXXFLAGS}")
set_source_files_properties(utils.cc PROPERTIES COMPILE_FLAGS "-DTOIT_MODEL=\"\\\"${TOIT_MODEL}\\\"\" -DVM_GIT_INFO=\"\\\"${VM_GIT_INFO}\\\"\" -DVM_GIT_VERSION=\"\\\"${TOIT_GIT_VERSION}\\\"\"")

set(GEN_DIR "${PROJECT_BINARY_DIR}/generated")
set(BOOT_SNAPSHOT ${GEN_DIR}/toit.run.snapshot)
set(BOOT_SNAPSHOT_CC ${GEN_DIR}/toit.run.snapshot.cc)
set(RUN_IMAGE_SNAPSHOT ${GEN_DIR}/run-image.snapshot)
set(RUN_IMAGE_IMAGE ${GEN_DIR}/run-image.image)
set(RUN_IMAGE_IMAGE_CC ${GEN_DIR}/run-image.image.cc)
set(TOIT_SNAPSHOT ${GEN_DIR}/toit.snapshot)
set(TOIT_SNAPSHOT_CC ${GEN_DIR}/toit.snapshot.cc)

add_custom_command(
  OUTPUT "${BOOT_SNAPSHOT_CC}"
  # We can't use ${BOOT_SNAPSHOT} here, as that would include the full path.
  # xxd just got a patch to change the name, but it's not really released/widely available yet.
  COMMAND xxd -i "toit.run.snapshot" "${BOOT_SNAPSHOT_CC}"
  DEPENDS "${BOOT_SNAPSHOT}"
  WORKING_DIRECTORY "${GEN_DIR}"
)

add_custom_target(build_boot_snapshot DEPENDS ${BOOT_SNAPSHOT_CC})

add_custom_command(
  OUTPUT "${TOIT_SNAPSHOT_CC}"
  # We can't use ${TOIT_SNAPSHOT} here, as that would include the full path.
  # xxd just got a patch to change the name, but it's not really released/widely available yet.
  COMMAND xxd -i "toit.snapshot" "${TOIT_SNAPSHOT_CC}"
  DEPENDS "${TOIT_SNAPSHOT}"
  WORKING_DIRECTORY "${GEN_DIR}"
)

add_custom_command(
  OUTPUT "${RUN_IMAGE_IMAGE_CC}"
  # We can't use ${RUN_IMAGE_IMAGE} here, as that would include the full path.
  # xxd just got a patch to change the name, but it's not really released/widely available yet.
  COMMAND xxd -i "run-image.image" "${RUN_IMAGE_IMAGE_CC}"
  DEPENDS "${RUN_IMAGE_IMAGE}"
  WORKING_DIRECTORY "${GEN_DIR}"
)

# If the target architecture is 32-bit use -m32; otherwise -m64.
if (CMAKE_SIZEOF_VOID_P EQUAL 4)
  set(RUN_IMAGE_ARCH_FLAG "-m32")
else()
  set(RUN_IMAGE_ARCH_FLAG "-m64")
endif()
add_custom_command(
  OUTPUT "${RUN_IMAGE_IMAGE}"
  COMMAND "${HOST_TOIT}" run --
      "${CMAKE_SOURCE_DIR}/tools/snapshot_to_image.toit"
      -o "${RUN_IMAGE_IMAGE}"
      --format binary
      "${RUN_IMAGE_ARCH_FLAG}"
      "${RUN_IMAGE_SNAPSHOT}"
  DEPENDS "${HOST_TOIT}" ${RUN_IMAGE_SNAPSHOT}
)

if (NOT "${TOIT_SYSTEM_NAME}" MATCHES "esp32")
  add_executable(
    toit
    toit.cc
    ${TOIT_SNAPSHOT_CC}
    ${BOOT_SNAPSHOT_CC}
    ${run_SRC}
    )
  # Add the external programs as dependencies, so we can start using the 'toit'
  # executable once it's built.
  # This doesn't include toit.pkg, though.
  add_dependencies(toit
      toit.run
      toit.compile
  )

  add_dependencies(build_tools toit)

  add_executable(
    toit.run
    toit_run.cc
    ${BOOT_SNAPSHOT_CC}
    ${run_SRC}
    )

  add_dependencies(build_tools toit.run)

  add_executable(
    toit_run_image
    toit_run_image.cc
    ${RUN_IMAGE_IMAGE_CC}
    )

  add_dependencies(build_tools toit_run_image)

  set_target_properties(toit_run_image
    PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/run_image"
    )
endif()

# On linux, we need to link statically against libgcc as well.
if ("${CMAKE_SYSTEM_NAME}" MATCHES "Linux")
  set(TOIT_LINK_LIBS_LIBGCC -static-libgcc)

  if (NOT ${TOIT_IS_CROSS})
    find_library(SEGFAULT_LIB SegFault)
    if (SEGFAULT_LIB)
      set(TOIT_LINK_SEGFAULT SegFault)
    endif()
  endif()
endif()

if (${TOIT_IS_CROSS})
  set(TOIT_ALL_STATIC -static)
endif()

if (DEFINED USE_LWIP)
  set(TOIT_NETWORK_LIBS mbedtls ${LWIP_SANITIZER_LIBS} lwipcore lwipcontribportunix)
else()
  set(TOIT_NETWORK_LIBS mbedtls)
endif()

if ("${CMAKE_SYSTEM_NAME}" MATCHES "MSYS")
  set(TOIT_WINDOWS_LIBS ws2_32 rpcrt4 shlwapi crypt32)
elseif ("${CMAKE_SYSTEM_NAME}" MATCHES "Windows")
  set(TOIT_WINDOWS_LIBS rpcrt4 shlwapi crypt32)
else()
  set(TOIT_WINDOWS_LIBS )
endif()

if (${CMAKE_SYSTEM_NAME} MATCHES "Darwin")
  set(TOIT_BLUETOOTH_LIBS "-framework Foundation" "-framework CoreBluetooth" ObjC)
endif()

if (${CMAKE_SYSTEM_NAME} MATCHES "Darwin" OR (${CMAKE_SYSTEM_NAME} MATCHES "Linux" AND NOT CMAKE_SIZEOF_VOID_P EQUAL 4 AND NOT ${CMAKE_SYSTEM_PROCESSOR} MATCHES "ARM"))
  set(TOIT_Z_LIB z)
endif()

# Because of the `CACHE INTERNAL ""` at the end of the `set` we can
#   use this variable outside of the directory.
set(TOIT_LINK_LIBS
  ${TOIT_ALL_STATIC}
  -static-libstdc++
  ${TOIT_LINK_GC_FLAGS}
  ${TOIT_LINK_GROUP_BEGIN_FLAGS}
  toit_vm
  ${TOIT_NETWORK_LIBS}
  ${TOIT_LINK_GROUP_END_FLAGS}
  toit_compiler          # TODO(florian): should not be here by default.
  pthread
  ${TOIT_Z_LIB}
  ${CMAKE_DL_LIBS}
  ${TOIT_LINK_LIBS_LIBGCC}
  ${TOIT_LINK_SEGFAULT}
  toit_porting
  ${TOIT_BLUETOOTH_LIBS}
  ${EXTERNAL_TOIT_LIBS}
  CACHE INTERNAL ""
  )

target_link_libraries(
  toit_vm
  ${TOIT_WINDOWS_LIBS}
)

if (NOT "${TOIT_SYSTEM_NAME}" MATCHES "esp32")
  add_custom_target(build_vessels)
  add_dependencies(build_tools build_vessels)

  target_link_libraries(
    toit
    ${TOIT_LINK_LIBS}
    )

  target_link_libraries(
    toit.run
    ${TOIT_LINK_LIBS}
    )

  target_link_libraries(
    toit_run_image
    ${TOIT_LINK_LIBS}
    )
  # Since the run-image is stored in the envelope we would like it to be small, so
  # that OTA updates are smaller.
  set_target_properties(toit_run_image
    PROPERTIES
    LINK_FLAGS_RELEASE "-s"
    )

  set(ENVELOPE "${CMAKE_BINARY_DIR}/firmware.envelope")

  add_custom_command(
    OUTPUT "${ENVELOPE}"
    COMMAND ${HOST_TOIT} tool firmware create host
        -e "${ENVELOPE}"
        --word-size ${CMAKE_SIZEOF_VOID_P}
        --run-image "$<TARGET_FILE:toit_run_image>"
    DEPENDS ${HOST_TOIT} toit_run_image
  )
  add_custom_target(
    build_envelope
    DEPENDS ${ENVELOPE}
  )
  add_dependencies(build_tools build_envelope)

  set(VESSEL_SIZES 128 256 512 1024 8192)
  foreach(VESSEL_SIZE ${VESSEL_SIZES})
    set(VESSEL_TARGET vessel${VESSEL_SIZE})
    add_executable(
      ${VESSEL_TARGET}
      vessel.cc
      vessel/vessel${VESSEL_SIZE}.cc
      ${BOOT_SNAPSHOT_CC}
      ${run_SRC}
    )
    target_link_libraries(
      ${VESSEL_TARGET} ${TOIT_LINK_LIBS}
    )

    set_target_properties(${VESSEL_TARGET}
      PROPERTIES
      RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/sdk/vessels"
    )
    set_target_properties(${VESSEL_TARGET}
      PROPERTIES
      LINK_FLAGS_RELEASE "-s"
    )

    # Unsign the vessel executables.
    if ("${CMAKE_SYSTEM_NAME}" MATCHES "Darwin")
      add_custom_command(
        TARGET ${VESSEL_TARGET}
        POST_BUILD
        COMMAND "codesign" "--remove-signature" "${VESSEL_TARGET}"
        WORKING_DIRECTORY "${CMAKE_BINARY_DIR}/sdk/vessels"
        COMMENT "Removing signature from vessel executable"
      )
    endif()

    add_dependencies(build_vessels ${VESSEL_TARGET})
  endforeach()
  include(${TOIT_SDK_SOURCE_DIR}/tools/toit.cmake)

  set(BOOT_SNAPSHOT_SOURCE ${TOIT_SDK_SOURCE_DIR}/system/extensions/host/toit.run.toit)
  ADD_TOIT_SNAPSHOT(
    ${BOOT_SNAPSHOT_SOURCE}
    ${BOOT_SNAPSHOT}
    ${CMAKE_CURRENT_BINARY_DIR}/boot.dep
    ""
  )

  set(TOIT_SNAPSHOT_SOURCE ${TOIT_SDK_SOURCE_DIR}/tools/toit.toit)
  ADD_TOIT_SNAPSHOT(
    ${TOIT_SNAPSHOT_SOURCE}
    ${TOIT_SNAPSHOT}
    ${CMAKE_CURRENT_BINARY_DIR}/toit.dep
    ""
  )

  set(RUN_IMAGE_SNAPSHOT_SOURCE ${TOIT_SDK_SOURCE_DIR}/system/extensions/host/run-image.toit)
  ADD_TOIT_SNAPSHOT(
    ${RUN_IMAGE_SNAPSHOT_SOURCE}
    ${RUN_IMAGE_SNAPSHOT}
    ${CMAKE_CURRENT_BINARY_DIR}/run-image.dep
    ""
  )

  if (DEFINED USE_LWIP)
    include_directories(toit.run PRIVATE ${LWIP_INCLUDE_DIRS})
    target_compile_options(toit.run PRIVATE ${LWIP_COMPILER_FLAGS})
    target_compile_definitions(toit.run PRIVATE ${LWIP_DEFINITIONS} ${LWIP_MBEDTLS_DEFINITIONS})
  endif()
endif() # TOIT_SYSTEM_NAME != esp32
