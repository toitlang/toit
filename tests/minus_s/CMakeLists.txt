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

file(GLOB MINUS_S_TESTS RELATIVE ${CMAKE_CURRENT_SOURCE_DIR} "*_test.snippet")

add_custom_target(update_minus_s_gold)

foreach(file ${MINUS_S_TESTS})
  get_filename_component(name ${file} NAME_WE)
  set(lib_dir ".")
  set(toit_file ${CMAKE_CURRENT_SOURCE_DIR}/${file})
  file(RELATIVE_PATH relative_negative_path ${CMAKE_CURRENT_SOURCE_DIR} ${toit_file})
  get_filename_component(relative_negative_dir "${relative_negative_path}" DIRECTORY)
  set(gold_file ${CMAKE_CURRENT_SOURCE_DIR}/gold/${relative_negative_dir}/${name}.gold)
  file(RELATIVE_PATH relative ${TOIT_SDK_SOURCE_DIR} ${toit_file})
  string(REPLACE " " "__" test_name ${relative})
  add_test(
    NAME ${test_name}
    COMMAND ${CMAKE_CURRENT_SOURCE_DIR}/run.sh $<TARGET_FILE:toit.run> ${relative} ${gold_file}
    WORKING_DIRECTORY ${TOIT_SDK_SOURCE_DIR}
  )
  set_tests_properties(${test_name} PROPERTIES TIMEOUT 40)

  file(RELATIVE_PATH relative_gold ${TOIT_SDK_SOURCE_DIR} ${gold_file})
  string(REPLACE "/" "__" generate_gold ${relative_gold})
  string(REPLACE " " "__" generate_gold ${generate_gold})
  set(generate_gold "build_${generate_gold}")
  add_custom_target(${generate_gold})

  add_custom_command(
    TARGET ${generate_gold}
    COMMAND ${CMAKE_CURRENT_SOURCE_DIR}/run.sh --update $<TARGET_FILE:toit.run> ${relative} ${gold_file}
    WORKING_DIRECTORY ${TOIT_SDK_SOURCE_DIR}
    DEPENDS toitc
  )
  add_dependencies(update_minus_s_gold ${generate_gold})
endforeach()
