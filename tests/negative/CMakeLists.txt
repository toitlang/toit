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

file(GLOB TOIT_TESTS RELATIVE ${CMAKE_CURRENT_SOURCE_DIR} "*_test.toit" "**/*_test.toit")

add_custom_target(update_gold)

set(NORMALIZE_GOLD ${CMAKE_CURRENT_SOURCE_DIR}/../tools/normalize_gold.cmake)

include(fail.cmake)

foreach(file ${TOIT_TESTS})
  get_filename_component(name ${file} NAME_WE)
  set(lib_dir ".")
  set(toit_file ${CMAKE_CURRENT_SOURCE_DIR}/${file})
  file(RELATIVE_PATH relative_negative_path ${CMAKE_CURRENT_SOURCE_DIR} ${toit_file})
  get_filename_component(relative_negative_dir "${relative_negative_path}" DIRECTORY)
  set(gold_file ${CMAKE_CURRENT_SOURCE_DIR}/gold/${relative_negative_dir}/${name}.gold)
  file(RELATIVE_PATH relative ${TOIT_SDK_SOURCE_DIR} ${toit_file})
  string(REPLACE " " "__" test_name ${relative})

  if(NOT "${test_name}" IN_LIST TOIT_SKIP_TESTS)
    add_test(
      NAME ${test_name}
      COMMAND ${CMAKE_COMMAND}
          -DTOITVM=$<TARGET_FILE:toit.run>
          "-DTEST=${relative}"
          "-DGOLD=${gold_file}"
          "-DLIB_DIR=${lib_dir}"
          "-DNORMALIZE_GOLD=${NORMALIZE_GOLD}"
          "-DTEST_ROOT=${TOIT_SDK_SOURCE_DIR}"
          "-DGIT_VERSION=${TOIT_GIT_VERSION}"
          "-DTMP=${CMAKE_BINARY_DIR}/tmp"
          "-DCMAKE_SYSTEM_NAME=${CMAKE_SYSTEM_NAME}"
          -P "${CMAKE_CURRENT_SOURCE_DIR}/run.cmake"
      WORKING_DIRECTORY ${TOIT_SDK_SOURCE_DIR}
    )
    set_tests_properties(${test_name} PROPERTIES TIMEOUT 40)

    if("${test_name}" IN_LIST TOIT_FAILING_TESTS)
      set_tests_properties(${test_name} PROPERTIES WILL_FAIL TRUE)
    endif()
  endif()

  file(RELATIVE_PATH relative_gold ${TOIT_SDK_SOURCE_DIR} ${gold_file})
  string(REPLACE "/" "__" generate_gold ${relative_gold})
  string(REPLACE " " "__" generate_gold ${generate_gold})
  set(generate_gold "build_${generate_gold}")
  add_custom_target(${generate_gold})

  add_custom_command(
    TARGET ${generate_gold}
    COMMAND ${CMAKE_COMMAND}
        -DUPDATE_GOLD=true
        -DTOITVM=$<TARGET_FILE:toit.run>
        "-DTEST=${relative}"
        "-DGOLD=${gold_file}"
        "-DLIB_DIR=${lib_dir}"
        "-DNORMALIZE_GOLD=${NORMALIZE_GOLD}"
        "-DTEST_ROOT=${TOIT_SDK_SOURCE_DIR}"
        "-DGIT_VERSION=${TOIT_GIT_VERSION}"
        "-DTMP=${CMAKE_BINARY_DIR}/tmp"
        "-DCMAKE_SYSTEM_NAME=${CMAKE_SYSTEM_NAME}"
        -P "${CMAKE_CURRENT_SOURCE_DIR}/run.cmake"
    WORKING_DIRECTORY ${TOIT_SDK_SOURCE_DIR}
    DEPENDS toit.compile
  )
  add_dependencies(update_gold ${generate_gold})
endforeach()
