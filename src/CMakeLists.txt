add_subdirectory(compiler)

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

list(FILTER toit_core_SRC EXCLUDE REGEX "/(toit|toit_run_image).cc$")

file(GLOB toit_resources_SRC
  "resources/*.h"
  "resources/*.cc"
  )

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

set(toit_vm_SRC ${toit_resources_SRC} ${toit_event_sources_SRC} ${lwip_on_linux_sources_SRC} ${gc_sources_SRC})

add_library(
  toit_core
  ${toit_core_SRC}
  )

add_library(
  toit_vm
  ${toit_vm_SRC}
  ${toit_core_SRC}
  )

set_source_files_properties(interpreter_core.cc PROPERTIES COMPILE_FLAGS "-O3")
set_source_files_properties(interpreter_run.cc PROPERTIES COMPILE_FLAGS "-O3 ${TOIT_INTERPRETER_FLAGS} $ENV{LOCAL_INTERPRETER_CXXFLAGS}")
set_source_files_properties(utils.cc PROPERTIES COMPILE_FLAGS "-DTOIT_MODEL=\"\\\"${TOIT_MODEL}\\\"\" -DVM_GIT_INFO=\"\\\"${VM_GIT_INFO}\\\"\" -DVM_GIT_VERSION=\"\\\"${TOIT_GIT_VERSION}\\\"\"")

add_executable(
  toit.run
  toit.cc
  )

add_executable(
  toit_run_image
  toit_run_image.cc
  )

set_target_properties(toit_run_image
  PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/toit_run_image_test/bin"
  )

# On linux, we need to link statically against libgcc as well.
if ("${CMAKE_SYSTEM_NAME}" MATCHES "Linux")
  set(TOIT_LINK_LIBS_LIBGCC -static-libgcc)

  find_library(SEGFAULT_LIB SegFault)
  if (SEGFAULT_LIB)
    set(TOIT_LINK_SEGFAULT SegFault)
  endif()
endif()

if (DEFINED USE_LWIP)
  set(TOIT_NETWORK_LIBS mbedtls ${LWIP_SANITIZER_LIBS} lwipcore lwipcontribportunix)
else()
  set(TOIT_NETWORK_LIBS mbedtls)
endif()

if ("${CMAKE_SYSTEM_NAME}" MATCHES "MSYS")
  set(TOIT_WINDOWS_LIBS ws2_32 rpcrt4)
elseif ("${CMAKE_SYSTEM_NAME}" MATCHES "Windows")
  set(TOIT_WINDOWS_LIBS rpcrt4)
else()
  set(TOIT_WINDOWS_LIBS )
endif()

# Because of the `CACHE INTERNAL ""` at the end of the `set` we can
#   use this variable outside of the directory.
set(TOIT_LINK_LIBS
  -static-libstdc++
  ${TOIT_LINK_GC_FLAGS}
  ${TOIT_LINK_GROUP_BEGIN_FLAGS}
  toit_vm
  ${TOIT_NETWORK_LIBS}
  ${TOIT_LINK_GROUP_END_FLAGS}
  toit_compiler
  pthread
  ${CMAKE_DL_LIBS}
  ${TOIT_LINK_LIBS_LIBGCC}
  ${TOIT_LINK_SEGFAULT}
  CACHE INTERNAL ""
  )

target_link_libraries(
  toit_vm
  ${TOIT_WINDOWS_LIBS}
)

target_link_libraries(
  toit.run
  ${TOIT_LINK_LIBS}
  )

target_link_libraries(
  toit_run_image
  ${TOIT_LINK_LIBS}
  )

include(${TOIT_SDK_SOURCE_DIR}/tools/toit.cmake)

set(BOOT_SNAPSHOT ${CMAKE_BINARY_DIR}/sdk/bin/toit.run.snapshot)

ADD_TOIT_TARGET(
  ${TOIT_SDK_SOURCE_DIR}/tools/toit.run.toit
  ${BOOT_SNAPSHOT}
  ${CMAKE_CURRENT_BINARY_DIR}/boot.dep
  "ASAN_OPTIONS=detect_leaks=false"
)

add_custom_target(
  build_tools
  DEPENDS toit.run toit.compile
)

add_custom_target(
  build_boot_snapshot
  DEPENDS ${BOOT_SNAPSHOT}
)

add_dependencies(build_snapshots build_boot_snapshot)

if (DEFINED USE_LWIP)
  include_directories(toit.run PRIVATE ${LWIP_INCLUDE_DIRS})
  target_compile_options(toit.run PRIVATE ${LWIP_COMPILER_FLAGS})
  target_compile_definitions(toit.run PRIVATE ${LWIP_DEFINITIONS} ${LWIP_MBEDTLS_DEFINITIONS})
endif()

#ifdef IMAGE
enable_language(C ASM)

get_filename_component(TOIT_IMAGE "$ENV{IMAGE}" REALPATH BASE_DIR "${CMAKE_SOURCE_DIR}")

add_library(
  toit_image
  STATIC
  EXCLUDE_FROM_ALL
  ${TOIT_IMAGE}
)

set_target_properties(toit_image PROPERTIES LINKER_LANGUAGE ASM)
#endif
