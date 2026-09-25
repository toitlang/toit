# Copyright (C) 2026 Toit contributors.
#
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Lesser General Public
# License as published by the Free Software Foundation; version
# 2.1 only.

file(MAKE_DIRECTORY "${CMAKE_BINARY_DIR}/tmp")
file(GLOB FORMATTER_INPUTS RELATIVE "${CMAKE_CURRENT_SOURCE_DIR}/gold"
     "gold/*.toit")

add_custom_target(update_formatter_gold)

foreach(input ${FORMATTER_INPUTS})
  get_filename_component(name "${input}" NAME_WE)
  set(input_path "${CMAKE_CURRENT_SOURCE_DIR}/gold/${input}")
  set(gold_path "${CMAKE_CURRENT_SOURCE_DIR}/gold/${name}.gold")
  file(RELATIVE_PATH test_name "${TOIT_SDK_SOURCE_DIR}" "${input_path}")

  add_test(
    NAME "${test_name}"
    COMMAND ${CMAKE_COMMAND}
      -DTOIT=$<TARGET_FILE:toit>
      -DINPUT=${input_path}
      -DGOLD=${gold_path}
      -DTMP=${CMAKE_BINARY_DIR}/tmp
      -P "${CMAKE_CURRENT_SOURCE_DIR}/run.cmake"
  )
  set_tests_properties("${test_name}" PROPERTIES TIMEOUT ${DEFAULT_TIMEOUT})

  set(update_target "formatter_gold_${name}")
  add_custom_target(${update_target})
  add_custom_command(
    TARGET ${update_target}
    POST_BUILD
    COMMAND ${CMAKE_COMMAND}
      -DTOIT=$<TARGET_FILE:toit>
      -DINPUT=${input_path}
      -DGOLD=${gold_path}
      -DTMP=${CMAKE_BINARY_DIR}/tmp
      -DUPDATE_GOLD=true
      -P "${CMAKE_CURRENT_SOURCE_DIR}/run.cmake"
  )
  add_dependencies(${update_target} toit)
  add_dependencies(update_formatter_gold ${update_target})
endforeach()
