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

# Must be before the add_subdirectory(compiler) below, as that one
# uses the UTF_8_MANIFEST_LIB variable.
if ("${CMAKE_SYSTEM_NAME}" MATCHES "Windows" OR "${CMAKE_SYSTEM_NAME}" MATCHES "MSYS")
  add_library(utf8_manifest OBJECT
    manifest.rc
    manifest.xml
  )
  enable_language(RC)
  set(UTF_8_MANIFEST_LIB utf8_manifest)
endif()

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

set(EMBEDDED_TOIT_PROGRAMS toit toit_run run_image)

set(EMBEDDED_PROGRAM_SOURCE_toit "${CMAKE_SOURCE_DIR}/tools/toit.toit")
set(EMBEDDED_PROGRAM_SOURCE_toit_run "${TOIT_SDK_SOURCE_DIR}/system/extensions/host/toit.run.toit")
set(EMBEDDED_PROGRAM_SOURCE_run_image "${TOIT_SDK_SOURCE_DIR}/system/extensions/host/run-image.toit")

foreach (embedded_program ${EMBEDDED_TOIT_PROGRAMS})
  set(EMBEDDED_PROGRAM_SOURCE_${embedded_program} "${EMBEDDED_PROGRAM_SOURCE_${embedded_program}}")
  set(EMBEDDED_PROGRAM_SNAPSHOT_${embedded_program} "${GEN_DIR}/${embedded_program}.snapshot")
  set(EMBEDDED_PROGRAM_IMAGE_${embedded_program} "${GEN_DIR}/${embedded_program}.image")
  set(EMBEDDED_PROGRAM_SNAPSHOT_CC_${embedded_program} "${GEN_DIR}/${embedded_program}_snapshot.cc")
  set(EMBEDDED_PROGRAM_IMAGE_CC_${embedded_program} "${GEN_DIR}/${embedded_program}_image.cc")
endforeach()

add_custom_target(build_boot_snapshot DEPENDS "${EMBEDDED_PROGRAM_SNAPSHOT_CC_toit}")

if (NOT "${TOIT_SYSTEM_NAME}" MATCHES "esp32")
  add_executable(
    toit
    toit.cc
    "${EMBEDDED_PROGRAM_SNAPSHOT_CC_toit}"
    "${EMBEDDED_PROGRAM_SNAPSHOT_CC_toit_run}"
    ${run_SRC}
    )
  set_target_properties(toit PROPERTIES RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/sdk/bin")
  # Add the toit.{compile,run} as dependency, so we can start using the executable once it's built.
  # As soon as the 'toit' executable is built, it might be used to call `toit pkg` in
  # which case the `toit.pkg` executable is needed. That's why we add the `build_go_tools`
  # dependency.
  add_dependencies(toit toit.compile toit.run build_go_tools)
  add_dependencies(build_tools toit)

  add_executable(
    toit.run
    toit_run.cc
    "${EMBEDDED_PROGRAM_SNAPSHOT_CC_toit_run}"
    "${run_SRC}"
    )
  set_target_properties(toit.run PROPERTIES RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/sdk/lib/toit/bin")
  add_dependencies(build_tools toit.run)

  add_executable(
    toit_run_image
    toit_run_image.cc
    "${EMBEDDED_PROGRAM_IMAGE_CC_run_image}"
    )
  set_target_properties(toit_run_image
    PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/run_image"
    )
  add_dependencies(build_tools toit_run_image)
endif()

target_include_directories(toit_core PRIVATE "${TOIT_SDK_SOURCE_DIR}/third_party/dragonbox/include")
target_include_directories(toit_vm PRIVATE "${TOIT_SDK_SOURCE_DIR}/third_party/dragonbox/include")

# On linux, we need to link statically against libgcc as well.
if ("${CMAKE_SYSTEM_NAME}" MATCHES "Linux")
  target_link_libraries(toit_core PRIVATE gpiod::gpiod)
  target_link_libraries(toit_vm PRIVATE gpiod::gpiod)

  set(TOIT_LINK_LIBS_LIBGCC -static-libgcc)

  if (NOT ${TOIT_IS_CROSS})
    find_library(SEGFAULT_LIB SegFault)
    if (SEGFAULT_LIB)
      set(TOIT_LINK_SEGFAULT SegFault)
    endif()
  endif()
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

target_link_libraries(
  toit_vm
  ${UTF_8_MANIFEST_LIB}
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
      ${EMBEDDED_PROGRAM_SNAPSHOT_CC_toit_run}
      ${run_SRC}
    )
    target_link_libraries(
      ${VESSEL_TARGET} ${TOIT_LINK_LIBS}
    )

    set_target_properties(${VESSEL_TARGET}
      PROPERTIES
      RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/sdk/lib/toit/vessels"
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
        WORKING_DIRECTORY "${CMAKE_BINARY_DIR}/sdk/lib/toit/vessels"
        COMMENT "Removing signature from vessel executable"
      )
    endif()

    add_dependencies(build_vessels ${VESSEL_TARGET})

    # Install the vessels to /usr/lib/toit/vessels.
    install(TARGETS ${VESSEL_TARGET}
      RUNTIME DESTINATION lib/toit/vessels
    )
  endforeach()
  include(${TOIT_SDK_SOURCE_DIR}/tools/toit.cmake)

  if (NOT ${TOIT_IS_CROSS})
    add_custom_target(download_embedded_program_packages)

    # Prepare the pkg install for the embedded programs.
    set(embedded_program_dirs)

    foreach (embedded_program ${EMBEDDED_TOIT_PROGRAMS})
      get_filename_component(embedded_program_dir "${EMBEDDED_PROGRAM_SOURCE_${embedded_program}}" DIRECTORY)
      list(APPEND embedded_program_dirs "${embedded_program_dir}")
      # We don't use the '.packages' directory as usual, as this would lead to two different
      # targets being able to produce the same file. We will end up downloading these packages
      # again with the 'download_packages' target, but that's after we have built the 'toit' executable.
      set(EMBEDDED_PROGRAM_PACKAGES_DIR_${embedded_program} "${embedded_program_dir}/.packages-bootstrap")
      set(EMBEDDED_PROGRAM_PACKAGES_TIMESTAMP_${embedded_program} "${embedded_program_dir}/.packages-bootstrap/package-timestamp")
    endforeach()

    # Filter out duplicates.
    list(REMOVE_DUPLICATES embedded_program_dirs)

    foreach (embedded_program_dir ${embedded_program_dirs})
      set(package_lock "${embedded_program_dir}/package.lock")
      set(package_dir "${embedded_program_dir}/.packages-bootstrap")
      set(package_timestamp "${package_dir}/package-timestamp")
      # The host `toit` is the same as the one we are trying to compile.
      # We can't use it to download packages or compile itself.
      add_custom_command(
        OUTPUT "${package_timestamp}"
        COMMAND "${CMAKE_COMMAND}"
          "-DPACKAGE_LOCK_PATH=${package_lock}"
          "-DPACKAGES_DIR=${package_dir}"
          "-DQUIET=1"
           -P "${CMAKE_SOURCE_DIR}/tools/pkg-install.cmake"
        COMMAND ${CMAKE_COMMAND} -E touch "${package_timestamp}"

        # TODO(florian): enable this line again.
        # Currently we don't use it, as a `toit pkg install` writes the lock file, even if nothing
        # has changed. This would lead to unnecessary rebuilds.
        # DEPENDS "${package_lock}"

        # The working directory isn't really important, but we must set it to
        # something that exists, as the current bin-dir might not exist yet.
        WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}"
      )

      string(MD5 dir_hash "${embedded_program_dir}")
      add_custom_target(download_embedded_program_packages_${dir_hash} DEPENDS "${package_timestamp}")
      add_dependencies(download_embedded_program_packages download_embedded_program_packages_${dir_hash})

    endforeach()
  endif()

  foreach (embedded_program ${EMBEDDED_TOIT_PROGRAMS})
    set(embedded_source "${EMBEDDED_PROGRAM_SOURCE_${embedded_program}}")
    set(embedded_snapshot "${EMBEDDED_PROGRAM_SNAPSHOT_${embedded_program}}")
    set(embedded_image "${EMBEDDED_PROGRAM_IMAGE_${embedded_program}}")
    set(embedded_snapshot_cc "${EMBEDDED_PROGRAM_SNAPSHOT_CC_${embedded_program}}")
    set(embedded_image_cc "${EMBEDDED_PROGRAM_IMAGE_CC_${embedded_program}}")
    set(embedded_dep "${CMAKE_BINARY_DIR}/run_image/${embedded_program}.dep")
    set(embedded_packages_dir "${EMBEDDED_PROGRAM_PACKAGES_DIR_${embedded_program}}")
    set(embedded_packages_timestamp "${EMBEDDED_PROGRAM_PACKAGES_TIMESTAMP_${embedded_program}}")

    if (${TOIT_IS_CROSS})
      ADD_TOIT_SNAPSHOT(
        ${embedded_source}
        ${embedded_snapshot}
        ${embedded_dep}
        ""
      )
    else()
      # We can't use the 'ADD_TOIT_SNAPSHOT' here, as that one uses the 'toit'
      # executable which we are in the process of building.
      add_custom_command(
        OUTPUT "${embedded_snapshot}"
        DEPFILE "${embedded_dep}"
        DEPENDS "${embedded_packages_timestamp}" "${embedded_source}" "$<TARGET_FILE:toit.compile>"
        COMMAND ${CMAKE_COMMAND} -E env
            ASAN_OPTIONS=detect_leaks=false
            TOIT_PACKAGE_CACHE_PATHS="${embedded_packages_dir}"
          $<TARGET_FILE:toit.compile>
          --dependency-file "${embedded_dep}"
          --dependency-format ninja
          -O2
          -w "${embedded_snapshot}"
          "${embedded_source}"
      )
    endif()

    # If the target architecture is 32-bit use -m32; otherwise -m64.
    if (CMAKE_SIZEOF_VOID_P EQUAL 4)
      set(run_image_arch_flag "-m32")
    else()
      set(run_image_arch_flag "-m64")
    endif()
    add_custom_command(
      OUTPUT "${embedded_image}"
      COMMAND "${HOST_TOIT}" tool snapshot-to-image
          -o "${embedded_image}"
          --format binary
          "${run_image_arch_flag}"
          "${embedded_snapshot}"
      DEPENDS "${HOST_TOIT}" "${embedded_snapshot}"
    )

    set(snapshot_filename "${embedded_program}.snapshot")
    add_custom_command(
      OUTPUT "${embedded_snapshot_cc}"
      # Note: we can't use an absolute path for the '-i' argument..
      COMMAND xxd -i "${snapshot_filename}" "${embedded_snapshot_cc}"
      DEPENDS "${embedded_snapshot}"
      WORKING_DIRECTORY "${GEN_DIR}"
    )

    set(image_filename "${embedded_program}.image")
    add_custom_command(
      OUTPUT "${embedded_image_cc}"
      # Note: we can't use an absolute path for the '-i' argument..
      COMMAND xxd -i "${image_filename}" "${embedded_image_cc}"
      DEPENDS "${embedded_image}"
      WORKING_DIRECTORY "${GEN_DIR}"
    )

  endforeach()

  if (DEFINED USE_LWIP)
    include_directories(toit.run PRIVATE ${LWIP_INCLUDE_DIRS})
    target_compile_options(toit.run PRIVATE ${LWIP_COMPILER_FLAGS})
    target_compile_definitions(toit.run PRIVATE ${LWIP_DEFINITIONS} ${LWIP_MBEDTLS_DEFINITIONS})
  endif()

  # Install the main binary to /usr/bin.
  install(TARGETS toit
    RUNTIME DESTINATION bin
  )

  # Install other binaries to /usr/lib/toit/bin.
  install(TARGETS toit.run toit.compile
    RUNTIME DESTINATION lib/toit/bin
  )
endif() # TOIT_SYSTEM_NAME != esp32
