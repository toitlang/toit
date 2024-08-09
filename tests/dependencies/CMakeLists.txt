# Copyright (C) 2024 Toitware ApS.
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

file(GLOB DEPENDENCIES_TESTS "*-test.toit")

foreach(file ${DEPENDENCIES_TESTS})
  get_filename_component(name ${file} NAME_WE)
  file(RELATIVE_PATH test_name ${TOIT_SDK_SOURCE_DIR} ${file})
  add_test(
    NAME ${test_name}
    COMMAND $<TARGET_FILE:toit.run> "${file}" $<TARGET_FILE:toit.compile>
  )
  set_tests_properties(${test_name} PROPERTIES TIMEOUT 40)
endforeach()
