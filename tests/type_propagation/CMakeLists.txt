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

file(GLOB TOIT_TESTS RELATIVE ${CMAKE_CURRENT_SOURCE_DIR} "*_test.toit")

add_custom_target(update_type_gold)

include(fail.cmake)

foreach(file ${TOIT_TESTS})
  get_filename_component(name ${file} NAME_WE)
  set(lib_dir ".")
  set(toit_file ${CMAKE_CURRENT_SOURCE_DIR}/${file})
  file(RELATIVE_PATH relative_type_path ${CMAKE_CURRENT_SOURCE_DIR} ${toit_file})
  get_filename_component(relative_type_path "${relative_type_path}" DIRECTORY)
  set(gold_file ${CMAKE_CURRENT_SOURCE_DIR}/gold/${relative_type_path}/${name}.gold)
  file(RELATIVE_PATH relative ${TOIT_SDK_SOURCE_DIR} ${toit_file})
  string(REPLACE " " "__" test_name ${relative})

  if(NOT "${test_name}" IN_LIST TOIT_SKIP_TESTS)
    add_test(
      NAME ${test_name}
      COMMAND ${CMAKE_COMMAND}
          -DTOIT_VM=$<TARGET_FILE:toit.run>
          -DTOIT_COMPILE=$<TARGET_FILE:toit.compile>
          "-DTEST=${relative}"
          "-DTEST_NAME=${name}"
          "-DGOLD=${gold_file}"
          "-DTEST_ROOT=${TOIT_SDK_SOURCE_DIR}"
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

  file(RELATIVE_PATH relative_type_gold ${TOIT_SDK_SOURCE_DIR} ${gold_file})
  string(REPLACE "/" "__" generate_type_gold ${relative_type_gold})
  string(REPLACE " " "__" generate_type_gold ${generate_type_gold})
  set(generate_gold "build_${generate_type_gold}")
  add_custom_target(${generate_type_gold})

  add_custom_command(
    TARGET ${generate_type_gold}
    COMMAND ${CMAKE_COMMAND}
        -DUPDATE_GOLD=true
        -DTOIT_VM=$<TARGET_FILE:toit.run>
        -DTOIT_COMPILE=$<TARGET_FILE:toit.compile>
        "-DTEST=${relative}"
        "-DTEST_NAME=${name}"
        "-DGOLD=${gold_file}"
        "-DTEST_ROOT=${TOIT_SDK_SOURCE_DIR}"
        "-DTMP=${CMAKE_BINARY_DIR}/tmp"
        "-DCMAKE_SYSTEM_NAME=${CMAKE_SYSTEM_NAME}"
        -P "${CMAKE_CURRENT_SOURCE_DIR}/run.cmake"
    WORKING_DIRECTORY ${TOIT_SDK_SOURCE_DIR}
    DEPENDS toit.compile
  )
  add_dependencies(update_type_gold ${generate_type_gold})
endforeach()
