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

file(GLOB TOIT_RUN_IMAGE_TESTS "*_test.toit")

set(TOIT_RUN_IMAGE_TEST_DIR ${CMAKE_BINARY_DIR}/toit_run_image_test)

add_custom_target(build_toit_run_image DEPENDS $<TARGET_FILE:toit_run_image>)
add_dependencies(build_tools build_toit_run_image)
add_dependencies(check build_toit_run_image)
add_dependencies(check_slow build_toit_run_image)

foreach(file ${TOIT_RUN_IMAGE_TESTS})
  get_filename_component(base ${file} NAME_WE)
  string(REGEX REPLACE "_test$" "" test_name ${base})
  set(input ${CMAKE_CURRENT_SOURCE_DIR}/${test_name}_input.toit)

  set(snap ${TOIT_RUN_IMAGE_TEST_DIR}/${test_name}_input.snapshot)
  set(image ${TOIT_RUN_IMAGE_TEST_DIR}/${test_name}_input.img)
  set(dep ${TOIT_RUN_IMAGE_TEST_DIR}/${test_name}_input.dep)

  ADD_TOIT_TARGET(
    "${input}"
    "${snap}"
    "${dep}"
    "")

  add_custom_command(
    OUTPUT "${image}"
    DEPENDS "${snap}"
    COMMAND "${CMAKE_COMMAND}" -E env ASAN_OPTIONS=detect_leaks=false
        $<TARGET_FILE:toit.compile> -i "${image}" "${snap}"
  )

  set(build_img tests-toit_run_image-build_${test_name}_input)
  add_custom_target(${build_img} DEPENDS ${image})

  # Make sure the test input is built before we run the tests.
  add_dependencies(check ${build_img})
  add_dependencies(check_slow ${build_img})

  file(RELATIVE_PATH test_name ${TOIT_SDK_SOURCE_DIR} ${file})
  add_test(
    NAME ${test_name}
    COMMAND $<TARGET_FILE:toit.run> ${file} $<TARGET_FILE:toit_run_image> ${image}
    )
  set_tests_properties(${test_name} PROPERTIES TIMEOUT 40)
endforeach()
