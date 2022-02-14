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

file(GLOB S2I_TESTS RELATIVE "${TOIT_SDK_SOURCE_DIR}" "*_test.toit")
file(GLOB INPUT RELATIVE "${TOIT_SDK_SOURCE_DIR}" "*_input.toit")

set(S2I_TEST_DIR ${CMAKE_BINARY_DIR}/snapshot_to_image_test)

add_custom_target(build_toit_run_image DEPENDS $<TARGET_FILE:toit_run_image>)
add_dependencies(build_tools build_toit_run_image)

foreach(input ${INPUT})
  get_filename_component(base ${input} NAME_WLE)
  set(snap ${S2I_TEST_DIR}/${base}.snap)
  set(dep ${S2I_TEST_DIR}/${base}.dep)
  set(expected_out "${CMAKE_CURRENT_SOURCE_DIR}/${base}.out")

  ADD_TOIT_TARGET(
    "${TOIT_SDK_SOURCE_DIR}/${input}"
    ${snap}
    ${dep}
    "")

  set(build_snap tests-s2i-build_${base}_input)
  add_custom_target(${build_snap} DEPENDS ${snap})

  # Make sure the test input is built before we run the tests.
  add_dependencies(check ${build_snap})
  add_dependencies(check_slow ${build_snap})

  add_test(
    NAME "${input}"
    COMMAND "${CMAKE_COMMAND}"
        "-DSNAP=${snap}"
        "-DTOITVM=$<TARGET_FILE:toit.run>"
        "-DTOITC=$<TARGET_FILE:toit.compile>"
        "-DSNAPSHOT_TO_IMAGE=${TOIT_SDK_SOURCE_DIR}/tools/snapshot_to_image.toit"
        "-DASM=${CMAKE_ASM_COMPILER}"
        "-DRUN_IMAGE=$<TARGET_FILE:toit_run_image>"
        "-DEXPECTED_OUT=${expected_out}"
        "-DOUTPUT_PREFIX=${S2I_TEST_DIR}/${base}"
        "-DWORKING_DIR=${TOIT_SDK_SOURCE_DIR}"
        -P "${CMAKE_CURRENT_LIST_DIR}/image.cmake"
    )
  set_tests_properties(${test_name} PROPERTIES TIMEOUT 40)
endforeach()

foreach(file ${S2I_TESTS})
  get_filename_component(base ${file} NAME_WE)
  set(snap ${S2I_TEST_DIR}/${base}.snap)

  add_test(
    NAME "${file}"
    COMMAND "$<TARGET_FILE:toit.run>" "${file}"
        "${snap}"
        "$<TARGET_FILE:toit.run>"
        "${TOIT_SDK_SOURCE_DIR}/tools/snapshot_to_image.toit"
    WORKING_DIRECTORY "${TOIT_SDK_SOURCE_DIR}"
    )
  set_tests_properties(${test_name} PROPERTIES TIMEOUT 40)
endforeach()

include(fail.cmake)
foreach(test ${TOIT_FAILING_TESTS})
  set_tests_properties(${test} PROPERTIES WILL_FAIL TRUE)
endforeach()
