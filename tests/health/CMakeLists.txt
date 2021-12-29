# Copyright (C) 2021 Toitware ApS.
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

# Using GLOB is not recommended to find all files in a repository.
# We thus use a script that collects all toit files and include it as
#   cmake source.
include(health_sources.cmake OPTIONAL)

set(NORMALIZE_GOLD ${TOIT_SDK_SOURCE_DIR}/tests/tools/normalize_gold.sh)

add_custom_target(
  generate_health_sources
  COMMAND "${CMAKE_CURRENT_SOURCE_DIR}/generate_sources_list.sh" "${TOIT_SDK_SOURCE_DIR}" "${CMAKE_CURRENT_SOURCE_DIR}/health_sources.cmake"
)

add_custom_target(
  check_health
  COMMAND ${CMAKE_CTEST_COMMAND} -j${NUM_CPU} -T test -C health --output-on-failure
  USES_TERMINAL
  DEPENDS toitc generate_health_sources
  )

add_custom_target(
  clear_health_gold
  COMMAND rm -f "${CMAKE_CURRENT_SOURCE_DIR}/*.gold"
)

add_custom_target(
  update_health_gold
  DEPENDS generate_health_sources
)

foreach(file ${HEALTH_SOURCES})
  get_filename_component(name ${file} NAME_WE)
  file(RELATIVE_PATH relative ${TOIT_SDK_SOURCE_DIR} ${file})
  string(REPLACE " " "__" TEST_NAME ${relative})
  string(REPLACE "/" "__" ESCAPED ${TEST_NAME})
  set(GOLD ${CMAKE_CURRENT_SOURCE_DIR}/${ESCAPED}.gold)
  # We don't use the path relative to the compiler, as analyzing `lib/...` would not be
  #   recognized as core library.
  set(LIB_PATH ".")

  add_test(
    NAME ${TEST_NAME}
    COMMAND "${CMAKE_CURRENT_SOURCE_DIR}/run.sh" $<TARGET_FILE:toitc> "${relative}" "${GOLD}" "${LIB_PATH}" "${NORMALIZE_GOLD}" "${TOIT_SDK_SOURCE_DIR}"
    WORKING_DIRECTORY ${TOIT_SDK_SOURCE_DIR}
    CONFIGURATIONS health
    )
  set_tests_properties(${TEST_NAME} PROPERTIES TIMEOUT 40)

  set(generate_gold build-health-${ESCAPED}.gold)
  add_custom_target(${generate_gold})

  add_custom_command(
    TARGET ${generate_gold}
    COMMAND "${CMAKE_CURRENT_SOURCE_DIR}/run.sh" --update $<TARGET_FILE:toitc> "${relative}" "${GOLD}" "${LIB_PATH}" "${NORMALIZE_GOLD}" "${TOIT_SDK_SOURCE_DIR}"
    WORKING_DIRECTORY ${TOIT_SDK_SOURCE_DIR}
    DEPENDS toitc
  )
  add_dependencies(update_health_gold ${generate_gold})
endforeach()
