file(GLOB toit_compiler_SRC
    "*.h"
    "*.cc"
    "optimizations/*.h"
    "optimizations/*.cc"
)
list(FILTER toit_compiler_SRC EXCLUDE REGEX "/toitc.cc$")

add_subdirectory(third_party/libyaml)
add_subdirectory(third_party/semver)

add_library(
  toit_compiler
  ${toit_compiler_SRC}
  )

target_link_libraries(
  toit_compiler
  ${YAML_STATIC_LIB_NAME}
  ${SEMVER_STATIC_LIB_NAME}
)

add_executable(
  toitc
  toitc.cc
  )

target_link_libraries(toitc -static-libstdc++)

target_link_libraries(
  toitc
  toit_core
  toit_compiler
  mbedtls
  pthread
  ${CMAKE_DL_LIBS}
  )

if (APPLE)
  set(LN_FORCE "F")
else()
  set(LN_FORCE "Tf")
endif()

add_custom_command(
  OUTPUT ${CMAKE_RUNTIME_OUTPUT_DIRECTORY}/lib
  COMMAND ln -s${LN_FORCE} ${CMAKE_SOURCE_DIR}/lib ${CMAKE_RUNTIME_OUTPUT_DIRECTORY}/lib
  VERBATIM
)

add_custom_target(
  generate-lib-symlink
  DEPENDS ${CMAKE_RUNTIME_OUTPUT_DIRECTORY}/lib
  )

add_dependencies(toitc generate-lib-symlink)
