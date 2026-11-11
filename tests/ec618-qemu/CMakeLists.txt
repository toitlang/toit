# Copyright (C) 2026 Toit contributors.
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

# The EC618 VM library on QEMU's mps2-an385 (harness.cc). Configure the EC618
# build (toolchains/ec618.cmake, the Makefile's ec618-link) with
# -DTOIT_EC618_QEMU_HARNESS=ON -DEC618_BASE_ELF=<base.elf> and build
# `toit_ec618_qemu`; run.sh runs it.
#
# Two links: toit_ec618_qemu_probe leaves the base's functions unresolved,
# gen-stubs.sh turns the list into stubs (functions that stop the run, and
# data of the base's sizes, from EC618_BASE_ELF), and toit_ec618_qemu links
# with them.

set(EC618_BASE_ELF "" CACHE FILEPATH "The EC618 base the stubs take their symbol types from")
if (NOT EXISTS "${EC618_BASE_ELF}")
  message(FATAL_ERROR "TOIT_EC618_QEMU_HARNESS needs EC618_BASE_ELF (build/ec618-base/base.elf)")
endif()

set(EC618_PROJECT_SRC "${CMAKE_SOURCE_DIR}/toolchains/ec618/project/src")
set(HARNESS_SOURCES
  "${CMAKE_CURRENT_SOURCE_DIR}/harness.cc"
  "${CMAKE_CURRENT_SOURCE_DIR}/startup.c"
  "${CMAKE_CURRENT_SOURCE_DIR}/base.c"
  # The EC618 base's heap (cmpctmalloc behind FreeRTOS and newlib) and its
  # stack alignment fix for the prebuilt kernel.
  "${EC618_PROJECT_SRC}/heap_7.c"
  "${EC618_PROJECT_SRC}/cmpctmalloc/cmpctmalloc.c"
  "${EC618_PROJECT_SRC}/task_stack.c"
)

# The VM archive whole, as in the slot link: the primitive modules are only
# reached through strong definitions that override weak null tables
# (primitive.cc). The harness's own definitions come first and replace the
# archive's (--allow-multiple-definition, as the EC618 base links).
set(HARNESS_LIBRARIES
  -Wl,--start-group
  -Wl,--whole-archive toit_vm -Wl,--no-whole-archive
  mbedtls mbedx509 mbedcrypto
  "${EC618_PLAT_DIR}/libs/libfreertos.a"
)
if (TOIT_VERIFIED_CORE_ENABLED)
  list(APPEND HARNESS_LIBRARIES toit_verified_core)
endif()
list(APPEND HARNESS_LIBRARIES -Wl,--end-group m)

set(HARNESS_LINK_OPTIONS
  -nostartfiles  # nano.specs comes with the compile flags (toolchains/ec618.cmake).
  -T "${CMAKE_CURRENT_SOURCE_DIR}/mps2.ld"
  -Wl,--gc-sections -Wl,--allow-multiple-definition
  # As the EC618 base: newlib's allocator entry points reach cmpctmalloc.
  -Wl,--wrap=_malloc_r,--wrap=_free_r,--wrap=_realloc_r,--wrap=_memalign_r
  -Wl,--wrap=pxPortInitialiseStack
  # As the slot link (Makefile, ec618-link).
  -Wl,--wrap=time,--wrap=clock,--wrap=localtime,--wrap=gmtime
  -u _printf_float
)

function(harness_target name)
  add_executable(${name} ${ARGN})
  target_include_directories(${name} PRIVATE
    "${CMAKE_SOURCE_DIR}/src"
    "${EC618_PROJECT_SRC}/cmpctmalloc"
    $<TARGET_PROPERTY:toit_vm,INCLUDE_DIRECTORIES>)
  target_compile_definitions(${name} PRIVATE $<TARGET_PROPERTY:toit_vm,COMPILE_DEFINITIONS>)
  target_link_libraries(${name} PRIVATE ${HARNESS_LIBRARIES})
  target_link_options(${name} PRIVATE ${HARNESS_LINK_OPTIONS} "-Wl,-Map=${CMAKE_CURRENT_BINARY_DIR}/${name}.map")
  set_target_properties(${name} PROPERTIES SUFFIX ".elf" RUNTIME_OUTPUT_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}" LINK_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/mps2.ld")
endfunction()

harness_target(toit_ec618_qemu_probe ${HARNESS_SOURCES})
target_link_options(toit_ec618_qemu_probe PRIVATE -Wl,--unresolved-symbols=ignore-all)

set(HARNESS_STUBS "${CMAKE_CURRENT_BINARY_DIR}/stubs.c")
add_custom_command(
  OUTPUT "${HARNESS_STUBS}"
  COMMAND sh "${CMAKE_CURRENT_SOURCE_DIR}/gen-stubs.sh" "${CMAKE_NM}"
          $<TARGET_FILE:toit_ec618_qemu_probe> "${EC618_BASE_ELF}" "${HARNESS_STUBS}"
  DEPENDS toit_ec618_qemu_probe "${CMAKE_CURRENT_SOURCE_DIR}/gen-stubs.sh"
  COMMENT "Generating the stubs of the EC618 base for the QEMU harness"
  VERBATIM
)
harness_target(toit_ec618_qemu ${HARNESS_SOURCES} "${HARNESS_STUBS}")
