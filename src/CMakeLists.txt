add_subdirectory(compiler)

# Use D flags to switch tools to deterministic mode (no timestamps etc.)
# This is part of getting a reproducible build.  This flag is not available
# in the 'ar' used on macOS.
if (NOT (${CMAKE_SYSTEM_NAME} MATCHES "Darwin"))
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

set(toit_vm_SRC ${toit_resources_SRC} ${toit_event_sources_SRC} ${lwip_on_linux_sources_SRC})

add_library(
  toit_core
  ${toit_core_SRC}
  )

add_library(
  toit_vm
  ${toit_vm_SRC}
  ${toit_core_SRC}
  )

set_source_files_properties(interpreter_run.cc PROPERTIES COMPILE_FLAGS "-O3 ${TOIT_INTERPRETER_FLAGS} $ENV{LOCAL_INTERPRETER_CXXFLAGS}")
set_source_files_properties(utils.cc PROPERTIES COMPILE_FLAGS "-DTOIT_MODEL=\"\\\"${TOIT_MODEL}\\\"\" -DVM_GIT_INFO=\"\\\"${VM_GIT_INFO}\\\"\" -DVM_GIT_VERSION=\"\\\"${VM_GIT_VERSION}\\\"\"")

add_custom_command(
  OUTPUT  checksum.cc
  COMMAND python ${CMAKE_SOURCE_DIR}/tools/generate_checksum.py ${CMAKE_CURRENT_BINARY_DIR}/checksum.cc $<TARGET_FILE:toit_vm>
  DEPENDS toit_vm
  )

add_executable(
  toitvm
  toit.cc
  ${CMAKE_CURRENT_BINARY_DIR}/checksum.cc
  )

add_executable(
  toit_run_image
  toit_run_image.cc
  ${CMAKE_CURRENT_BINARY_DIR}/checksum.cc
  )

set_target_properties(toit_run_image
  PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/toit_run_image_test/bin"
  )

# On linux, we need to link statically against libgcc as well.
if (${CMAKE_SYSTEM_NAME} MATCHES "Linux")
  set(TOIT_LINK_LIBS_LIBGCC -static-libgcc)
  set(TOIT_LINK_SEGFAULT SegFault)
endif()

# Because of the `CACHE INTERNAL ""` at the end of the `set` we can
#   use this variable outside of the directory.
set(TOIT_LINK_LIBS
  -static-libstdc++
  ${TOIT_LINK_GC_FLAGS}
  ${TOIT_LINK_GROUP_BEGIN_FLAGS}
  toit_vm
  mbedtls
  ${TOIT_LINK_GROUP_END_FLAGS}
  toit_compiler
  pthread
  ${CMAKE_DL_LIBS}
  ${TOIT_LINK_LIBS_LIBGCC}
  ${TOIT_LINK_SEGFAULT}
  CACHE INTERNAL ""
  )

target_link_libraries(
  toitvm
  ${TOIT_LINK_LIBS}
  )

target_link_libraries(
  toit_run_image
  ${TOIT_LINK_LIBS}
  )

include(${CMAKE_SOURCE_DIR}/tools/toit.cmake)

set(BOOT_SNAPSHOT ${CMAKE_BINARY_DIR}/bin/toitvm_boot.snapshot)

ADD_TOIT_TARGET(
  ${CMAKE_SOURCE_DIR}/tools/toitvm_boot.toit
  ${BOOT_SNAPSHOT}
  ${CMAKE_CURRENT_BINARY_DIR}/boot.dep
  "ASAN_OPTIONS=detect_leaks=false"
)

add_custom_target(
  build_toitvm
  DEPENDS toitvm ${BOOT_SNAPSHOT}
)

if (DEFINED USE_LWIP)
  include_directories(toitvm PRIVATE ${LWIP_INCLUDE_DIRS})
  target_compile_options(toitvm PRIVATE ${LWIP_COMPILER_FLAGS})
  target_compile_definitions(toitvm PRIVATE ${LWIP_DEFINITIONS} ${LWIP_MBEDTLS_DEFINITIONS})
  target_link_libraries(toitvm ${LWIP_SANITIZER_LIBS} lwipcore lwipcontribportunix)
endif()

#ifdef IMAGE
enable_language(C ASM)

get_filename_component(TOIT_IMAGE "$ENV{IMAGE}" REALPATH BASE_DIR "${CMAKE_SOURCE_DIR}")

add_library(
  toit_image
  EXCLUDE_FROM_ALL
  ${CMAKE_CURRENT_BINARY_DIR}/checksum.cc
  ${TOIT_IMAGE}
)
#endif
