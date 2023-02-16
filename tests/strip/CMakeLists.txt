# Copyright (C) 2023 Toitware ApS.
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

file(GLOB STRIP_TESTS RELATIVE "${TOIT_SDK_SOURCE_DIR}" "*_test.toit")

foreach(file ${STRIP_TESTS})
  set(test_name "${file}")
  # Strip the extension.
  get_filename_component(file_no_extension ${file} NAME_WE)
  set(test_input "${CMAKE_CURRENT_SOURCE_DIR}/${file_no_extension}-input.toit")
  set(test_path ${TOIT_SDK_SOURCE_DIR}/${file})

  add_test(
    NAME ${test_name}
    COMMAND $<TARGET_FILE:toit.run> "${test_path}" "${test_input}" $<TARGET_FILE:toit.compile> $<TARGET_FILE:toit.run>
  )
  set_tests_properties(${test_name} PROPERTIES TIMEOUT 40)
endforeach()
