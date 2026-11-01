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

# Adds what the compiler needs for building native executables to the SDK:
# The headers for the generated code, the libraries, and a file with the flags.
# This must be included after all the libraries have been defined.

set(TOIT_NATIVE_DIR "${CMAKE_BINARY_DIR}/sdk/lib/toit/native")
set(TOIT_NATIVE_ARCHIVES)
set(TOIT_NATIVE_LINK_FLAGS)

# Goes through the link libraries and finds the static libraries they
# depend on. Everything that isn't a target is a flag for the linker.
function(toit_native_collect item)
  string(REGEX REPLACE "^\\$<LINK_ONLY:(.*)>$" "\\1" item "${item}")
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

# Static libraries depend on each other, which the
# linker only handles if it sees them in the right order.
if (NOT APPLE)
  foreach(archive ${TOIT_NATIVE_ARCHIVES})
    list(APPEND TOIT_NATIVE_LINK_FLAGS "@SDK@/lib/$<TARGET_FILE_NAME:${archive}>")
  endforeach()
endif()

list(REMOVE_DUPLICATES TOIT_NATIVE_ARCHIVES)
if (APPLE)
  # There are so many functions that the symbols would dominate the size.
  list(APPEND TOIT_NATIVE_LINK_FLAGS "-Wl,-x" "-Wl,-S")
else()
  list(APPEND TOIT_NATIVE_LINK_FLAGS "-Wl,--gc-sections" "-s")
endif()

# The defines must be the ones of the runtime, because they affect the object layouts.
string(TOUPPER "${CMAKE_BUILD_TYPE}" TOIT_NATIVE_BUILD_TYPE)
set(TOIT_NATIVE_DEFINES "-DTOIT_DEPLOY")
if (NOT "${TOIT_NATIVE_BUILD_TYPE}" STREQUAL "RELEASE")
  set(TOIT_NATIVE_DEFINES "-DTOIT_DEBUG")
endif()
if ("${TOIT_NATIVE_BUILD_TYPE}" STREQUAL "ASAN")
  list(APPEND TOIT_NATIVE_DEFINES "-DTOIT_ASAN")
endif()

# The return addresses must look like smis, which needs the alignment.
set(TOIT_NATIVE_COMPILE_FLAGS
  "-std=gnu++11" "-w" "-Wno-unused-command-line-argument" "-fno-exceptions" "-fno-rtti"
  "-ffunction-sections" "-fdata-sections" "-falign-functions=4"
  "-DTOIT_NATIVE_CODE" ${TOIT_NATIVE_DEFINES}
  "-I" "@SDK@/include"
)

string(REPLACE ";" " " TOIT_NATIVE_COMPILE_LINE "${TOIT_NATIVE_COMPILE_FLAGS}")
string(REPLACE ";" " " TOIT_NATIVE_LINK_LINE "${TOIT_NATIVE_LINK_FLAGS}")
file(GENERATE
  OUTPUT "${TOIT_NATIVE_DIR}/native.flags"
  CONTENT "${TOIT_NATIVE_COMPILE_LINE}\n${TOIT_NATIVE_LINK_LINE}\n"
)

file(GLOB TOIT_NATIVE_HEADERS CONFIGURE_DEPENDS "${TOIT_SDK_SOURCE_DIR}/src/*.h")
file(GLOB TOIT_NATIVE_DARTINO_HEADERS CONFIGURE_DEPENDS "${TOIT_SDK_SOURCE_DIR}/src/third_party/dartino/*.h")

set(TOIT_NATIVE_ARCHIVE_FILES)
foreach(archive ${TOIT_NATIVE_ARCHIVES})
  list(APPEND TOIT_NATIVE_ARCHIVE_FILES "$<TARGET_FILE:${archive}>")
endforeach()

add_custom_target(
  build_native_sdk
  COMMAND "${CMAKE_COMMAND}" -E make_directory
      "${TOIT_NATIVE_DIR}/lib" "${TOIT_NATIVE_DIR}/include/third_party/dartino"
  COMMAND "${CMAKE_COMMAND}" -E copy_if_different ${TOIT_NATIVE_ARCHIVE_FILES} "${TOIT_NATIVE_DIR}/lib"
  COMMAND "${CMAKE_COMMAND}" -E copy_if_different ${TOIT_NATIVE_HEADERS} "${TOIT_NATIVE_DIR}/include"
  COMMAND "${CMAKE_COMMAND}" -E copy_if_different ${TOIT_NATIVE_DARTINO_HEADERS}
      "${TOIT_NATIVE_DIR}/include/third_party/dartino"
  VERBATIM
)
add_dependencies(build_native_sdk ${TOIT_NATIVE_ARCHIVES})
add_dependencies(build_vessels build_native_sdk)

install(DIRECTORY "${TOIT_NATIVE_DIR}/" DESTINATION lib/toit/native)
