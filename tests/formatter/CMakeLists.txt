# Copyright (C) 2026 Toit contributors.
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

include(fail.cmake OPTIONAL)

# -- Toit-based tests (idempotence-test, round-trip-test, flat-dogfood-test)
file(GLOB FORMATTER_TESTS "*-test.toit")

foreach(file ${FORMATTER_TESTS})
  file(RELATIVE_PATH test_name ${TOIT_SDK_SOURCE_DIR} ${file})
  if (NOT "${test_name}" IN_LIST TOIT_SKIP_TESTS)
    set(TEST_EXPECTATION_NAME "${test_name}")
    if("${test_name}" IN_LIST TOIT_FAILING_TESTS)
      set(TEST_EXPECTATION_NAME "${test_name}-expected-to-fail")
    endif()

    add_test(
      NAME ${TEST_EXPECTATION_NAME}
      COMMAND $<TARGET_FILE:toit.run> ${file} $<TARGET_FILE:toit> ${TOIT_SDK_SOURCE_DIR}
      )
    # round-trip and flat-dogfood run format over every file in lib/.
    set_tests_properties(${TEST_EXPECTATION_NAME} PROPERTIES TIMEOUT ${SLOW_TIMEOUT})
    if ("${test_name}" IN_LIST TOIT_FAILING_TESTS)
      set_tests_properties(${TEST_EXPECTATION_NAME} PROPERTIES WILL_FAIL TRUE)
    endif()
  endif()
endforeach()

# -- Gold tests: one input `.toit` + one `.gold` per case.
file(MAKE_DIRECTORY "${CMAKE_BINARY_DIR}/tmp")

add_custom_target(update_formatter_gold)

function(add_gold_tests subdir mode)
  file(GLOB INPUTS RELATIVE "${CMAKE_CURRENT_SOURCE_DIR}/gold/${subdir}"
       "gold/${subdir}/*.toit")
  foreach(input ${INPUTS})
    get_filename_component(name "${input}" NAME_WE)
    set(input_path "${CMAKE_CURRENT_SOURCE_DIR}/gold/${subdir}/${input}")
    set(gold_path "${CMAKE_CURRENT_SOURCE_DIR}/gold/${subdir}/${name}.gold")

    file(RELATIVE_PATH test_name "${TOIT_SDK_SOURCE_DIR}" "${input_path}")

    add_test(
      NAME "${test_name}"
      COMMAND ${CMAKE_COMMAND}
        -DTOIT=$<TARGET_FILE:toit>
        -DINPUT=${input_path}
        -DGOLD=${gold_path}
        -DTMP=${CMAKE_BINARY_DIR}/tmp
        -DMODE=${mode}
        -P "${CMAKE_CURRENT_SOURCE_DIR}/run.cmake"
    )
    set_tests_properties("${test_name}" PROPERTIES TIMEOUT ${DEFAULT_TIMEOUT})

    # Per-case target to regenerate the gold. `ninja update_formatter_gold`
    # runs all of them.
    set(update_target "fmt_gold_${subdir}_${name}")
    add_custom_target(${update_target})
    add_custom_command(
      TARGET ${update_target}
      POST_BUILD
      COMMAND ${CMAKE_COMMAND}
        -DTOIT=$<TARGET_FILE:toit>
        -DINPUT=${input_path}
        -DGOLD=${gold_path}
        -DTMP=${CMAKE_BINARY_DIR}/tmp
        -DMODE=${mode}
        -DUPDATE_GOLD=true
        -P "${CMAKE_CURRENT_SOURCE_DIR}/run.cmake"
    )
    add_dependencies(${update_target} toit.compile)
    add_dependencies(update_formatter_gold ${update_target})
  endforeach()
endfunction()

add_gold_tests("normal" "normal")
add_gold_tests("flat" "flat")
