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

# Adds what the compiler needs for building native executables to the SDK: the
# libraries and a file with the flags. The generated code needs no other files.
# This must be included after all the libraries have been defined.

set(TOIT_NATIVE_DIR "${CMAKE_BINARY_DIR}/sdk/lib/toit/native")
set(TOIT_NATIVE_ARCHIVES)
set(TOIT_NATIVE_LINK_FLAGS)

# Goes through the link libraries and finds the static libraries they
# depend on. Everything that isn't a target is a flag for the linker.
function(toit_native_collect item)
  string(REGEX REPLACE "^\\$<LINK_ONLY:(.*)>$" "\\1" item "${item}")
  # Native executables have no bytecodes to interpret.
  if ("${item}" STREQUAL "toit_interpreter")
    return()
  endif()
  if (NOT TARGET "${item}")
    if (NOT "${item}" MATCHES "^(-|/)")
      set(item "-l${item}")
    endif()
    list(APPEND TOIT_NATIVE_LINK_FLAGS "${item}")
    set(TOIT_NATIVE_LINK_FLAGS "${TOIT_NATIVE_LINK_FLAGS}" PARENT_SCOPE)
    return()
  endif()
  if ("${item}" IN_LIST TOIT_NATIVE_ARCHIVES)
    return()
  endif()
  get_target_property(type "${item}" TYPE)
  if ("${type}" STREQUAL "STATIC_LIBRARY")
    list(APPEND TOIT_NATIVE_ARCHIVES "${item}")
    list(APPEND TOIT_NATIVE_LINK_FLAGS "@SDK@/lib/$<TARGET_FILE_NAME:${item}>")
    get_target_property(dependencies "${item}" LINK_LIBRARIES)
  else()
    get_target_property(dependencies "${item}" INTERFACE_LINK_LIBRARIES)
  endif()
  if (dependencies)
    foreach(dependency ${dependencies})
      toit_native_collect("${dependency}")
    endforeach()
  endif()
  set(TOIT_NATIVE_ARCHIVES "${TOIT_NATIVE_ARCHIVES}" PARENT_SCOPE)
  set(TOIT_NATIVE_LINK_FLAGS "${TOIT_NATIVE_LINK_FLAGS}" PARENT_SCOPE)
endfunction()

toit_native_collect(toit_native_main)

# The generated code references what it needs, so the
# linker can leave the rest out. That includes system libraries.
list(REMOVE_ITEM TOIT_NATIVE_LINK_FLAGS "-Wl,-all_load" "-Wl,--whole-archive" "-Wl,--no-whole-archive")
if (APPLE)
  list(APPEND TOIT_NATIVE_LINK_FLAGS "-Wl,-dead_strip_dylibs")
else()
  list(PREPEND TOIT_NATIVE_LINK_FLAGS "-Wl,--as-needed")
endif()

# Static libraries depend on each other, which the
# linker only handles if it sees them in the right order.
if (NOT APPLE)
  foreach(archive ${TOIT_NATIVE_ARCHIVES})
    list(APPEND TOIT_NATIVE_LINK_FLAGS "@SDK@/lib/$<TARGET_FILE_NAME:${archive}>")
  endforeach()
endif()

list(REMOVE_DUPLICATES TOIT_NATIVE_ARCHIVES)

# This must be the last library on the link line.
list(APPEND TOIT_NATIVE_ARCHIVES toit_native_stubs)
list(APPEND TOIT_NATIVE_LINK_FLAGS "@SDK@/lib/$<TARGET_FILE_NAME:toit_native_stubs>")
if (APPLE)
  # There are so many functions that the symbols would dominate the size.
  # Native code has its own unwinding on the Toit stack. The compiler
  # flags for this don't remove the tables on arm64, so the linker has to.
  list(APPEND TOIT_NATIVE_LINK_FLAGS "-Wl,-x" "-Wl,-S" "-Wl,-no_compact_unwind")
else()
  list(APPEND TOIT_NATIVE_LINK_FLAGS "-Wl,--gc-sections" "-s")
endif()

set(TOIT_NATIVE_COMPILE_FLAGS
  "-std=gnu++11" "-w" "-Wno-unused-command-line-argument" "-fno-exceptions" "-fno-rtti"
  "-ffunction-sections" "-fdata-sections"
  "-fno-unwind-tables" "-fno-asynchronous-unwind-tables"
)

# The system program is native code too. It goes through the same steps as
# the programs in the executables, so it is only compiled once if we can.
set(TOIT_NATIVE_SYSTEM_SOURCE "${TOIT_SDK_SOURCE_DIR}/system/extensions/host/toit.run.toit")
set(TOIT_NATIVE_SYSTEM_CC "${TOIT_NATIVE_DIR}/system.cc")
set(TOIT_NATIVE_SYSTEM_OBJECT "${TOIT_NATIVE_DIR}/system.o")
add_custom_command(
  OUTPUT "${TOIT_NATIVE_SYSTEM_CC}"
  DEPENDS toit.compile "${TOIT_NATIVE_SYSTEM_SOURCE}"
  COMMAND "${CMAKE_COMMAND}" -E make_directory "${TOIT_NATIVE_DIR}"
  COMMAND "${CMAKE_COMMAND}" -E env
      "TOIT_PACKAGE_CACHE_PATHS=${TOIT_SDK_SOURCE_DIR}/system/extensions/host/.packages-bootstrap"
      $<TARGET_FILE:toit.compile> --native-boot -o "${TOIT_NATIVE_SYSTEM_CC}" "${TOIT_NATIVE_SYSTEM_SOURCE}"
  VERBATIM
)
find_program(TOIT_NATIVE_SDK_CXX clang++)
if (TOIT_NATIVE_SDK_CXX)
  set(TOIT_NATIVE_ARCH_FLAGS)
  if (APPLE)
    foreach(arch ${CMAKE_OSX_ARCHITECTURES})
      list(APPEND TOIT_NATIVE_ARCH_FLAGS "-arch" "${arch}")
    endforeach()
  endif()
  add_custom_command(
    OUTPUT "${TOIT_NATIVE_SYSTEM_OBJECT}"
    DEPENDS "${TOIT_NATIVE_SYSTEM_CC}"
    COMMAND "${TOIT_NATIVE_SDK_CXX}" ${TOIT_NATIVE_COMPILE_FLAGS} ${TOIT_NATIVE_ARCH_FLAGS} -O2
        -c "${TOIT_NATIVE_SYSTEM_CC}" -o "${TOIT_NATIVE_SYSTEM_OBJECT}"
    VERBATIM
  )
  list(PREPEND TOIT_NATIVE_LINK_FLAGS "@SDK@/system.o")
  set(TOIT_NATIVE_SYSTEM_OUTPUT "${TOIT_NATIVE_SYSTEM_OBJECT}")
else()
  list(PREPEND TOIT_NATIVE_LINK_FLAGS "@SDK@/system.cc")
  set(TOIT_NATIVE_SYSTEM_OUTPUT "${TOIT_NATIVE_SYSTEM_CC}")
endif()

string(REPLACE ";" " " TOIT_NATIVE_COMPILE_LINE "${TOIT_NATIVE_COMPILE_FLAGS}")
string(REPLACE ";" " " TOIT_NATIVE_LINK_LINE "${TOIT_NATIVE_LINK_FLAGS}")
file(GENERATE
  OUTPUT "${TOIT_NATIVE_DIR}/native.flags"
  CONTENT "${TOIT_NATIVE_COMPILE_LINE}\n${TOIT_NATIVE_LINK_LINE}\n"
)

set(TOIT_NATIVE_ARCHIVE_FILES)
foreach(archive ${TOIT_NATIVE_ARCHIVES})
  list(APPEND TOIT_NATIVE_ARCHIVE_FILES "$<TARGET_FILE:${archive}>")
endforeach()

# The default build keeps the native SDK up to date, so native code is never
# linked with an old runtime.
add_custom_target(
  build_native_sdk
  ALL
  DEPENDS "${TOIT_NATIVE_SYSTEM_OUTPUT}"
  COMMAND "${CMAKE_COMMAND}" -E make_directory "${TOIT_NATIVE_DIR}/lib"
  COMMAND "${CMAKE_COMMAND}" -E copy_if_different ${TOIT_NATIVE_ARCHIVE_FILES} "${TOIT_NATIVE_DIR}/lib"
  VERBATIM
)
add_dependencies(build_native_sdk ${TOIT_NATIVE_ARCHIVES} build_boot_snapshot)
add_dependencies(build_vessels build_native_sdk)

install(DIRECTORY "${TOIT_NATIVE_DIR}/" DESTINATION lib/toit/native)
