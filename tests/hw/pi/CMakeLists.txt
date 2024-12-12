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

file(GLOB TOIT_TESTS RELATIVE ${CMAKE_CURRENT_SOURCE_DIR} "*-test.toit")

add_custom_target(
  check_pi
  COMMAND ${CMAKE_CTEST_COMMAND} -j1 -T test -C pi --output-on-failure
  USES_TERMINAL
  )

foreach(file ${TOIT_TESTS})
  get_filename_component(name ${file} NAME_WE)
  set(toit_file ${CMAKE_CURRENT_SOURCE_DIR}/${file})
  set(test_name ${name})

  add_test(
    NAME ${file}
    COMMAND ${HW_TOIT_EXE} ${toit_file}
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    CONFIGURATIONS pi
    )

  set_tests_properties(${file} PROPERTIES TIMEOUT 40)
endforeach()
