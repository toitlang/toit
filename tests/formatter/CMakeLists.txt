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

file(MAKE_DIRECTORY "${CMAKE_BINARY_DIR}/tmp")
file(GLOB TOIT_TESTS RELATIVE ${CMAKE_CURRENT_SOURCE_DIR} "*-test.toit" "**/*-test.toit")

add_custom_target(update_formatter_gold)

set(NORMALIZE_GOLD ${CMAKE_CURRENT_SOURCE_DIR}/../tools/normalize_gold.cmake)

include(fail.cmake OPTIONAL)

foreach(file ${TOIT_TESTS})
  get_filename_component(name ${file} NAME_WE)
  set(toit_file ${CMAKE_CURRENT_SOURCE_DIR}/${file})
  file(RELATIVE_PATH relative_formatter_path ${CMAKE_CURRENT_SOURCE_DIR} ${toit_file})
  get_filename_component(relative_formatter_dir "${relative_formatter_path}" DIRECTORY)
  set(gold_file ${CMAKE_CURRENT_SOURCE_DIR}/gold/${relative_formatter_dir}/${name}.gold)
  file(RELATIVE_PATH relative ${TOIT_SDK_SOURCE_DIR} ${toit_file})
  string(REPLACE " " "__" test_name ${relative})

  set(TEST_EXPECTATION_NAME "${test_name}")

  add_test(
    NAME ${TEST_EXPECTATION_NAME}
    COMMAND ${CMAKE_COMMAND}
        -DTOITVM=$<TARGET_FILE:toit.run>
        -DTOIT_COMPILE=$<TARGET_FILE:toit.compile>
        "-DTEST=${relative}"
        "-DGOLD=${gold_file}"
        "-DNORMALIZE_GOLD=${NORMALIZE_GOLD}"
        "-DTEST_ROOT=${TOIT_SDK_SOURCE_DIR}"
        "-DGIT_VERSION=${TOIT_GIT_VERSION}"
        "-DTMP=${CMAKE_BINARY_DIR}/tmp"
        "-DCMAKE_SYSTEM_NAME=${CMAKE_SYSTEM_NAME}"
        -P "${CMAKE_CURRENT_SOURCE_DIR}/run.cmake"
    WORKING_DIRECTORY ${TOIT_SDK_SOURCE_DIR}
  )
  set_tests_properties(${TEST_EXPECTATION_NAME} PROPERTIES TIMEOUT 40)

  file(RELATIVE_PATH relative_gold ${TOIT_SDK_SOURCE_DIR} ${gold_file})
  string(REPLACE "/" "__" generate_gold ${relative_gold})
  string(REPLACE " " "__" generate_gold ${generate_gold})
  set(generate_gold "build_${generate_gold}")
  add_custom_target(${generate_gold})
  add_dependencies(${generate_gold} toit.compile)

  add_custom_command(
    TARGET ${generate_gold}
    POST_BUILD
    COMMAND ${CMAKE_COMMAND}
        -DUPDATE_GOLD=true
        -DTOITVM=$<TARGET_FILE:toit.run>
        -DTOIT_COMPILE=$<TARGET_FILE:toit.compile>
        "-DTEST=${relative}"
        "-DGOLD=${gold_file}"
        "-DNORMALIZE_GOLD=${NORMALIZE_GOLD}"
        "-DTEST_ROOT=${TOIT_SDK_SOURCE_DIR}"
        "-DGIT_VERSION=${TOIT_GIT_VERSION}"
        "-DTMP=${CMAKE_BINARY_DIR}/tmp"
        "-DCMAKE_SYSTEM_NAME=${CMAKE_SYSTEM_NAME}"
        -P "${CMAKE_CURRENT_SOURCE_DIR}/run.cmake"
    WORKING_DIRECTORY ${TOIT_SDK_SOURCE_DIR}
  )
  add_dependencies(update_formatter_gold ${generate_gold})
endforeach()

# Idempotency test over the whole standard library.
add_test(
  NAME tests/formatter/lib_idempotency
  COMMAND ${CMAKE_COMMAND}
      -DTOIT_COMPILE=$<TARGET_FILE:toit.compile>
      "-DLIB_DIR=${TOIT_SDK_SOURCE_DIR}/lib"
      "-DTMP=${CMAKE_BINARY_DIR}/tmp"
      -P "${CMAKE_CURRENT_SOURCE_DIR}/lib_idempotency.cmake"
  WORKING_DIRECTORY ${TOIT_SDK_SOURCE_DIR}
)
set_tests_properties(tests/formatter/lib_idempotency PROPERTIES TIMEOUT 300)
