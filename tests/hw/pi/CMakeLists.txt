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
  set(toit_file ${CMAKE_CURRENT_SOURCE_DIR}/${file})
  set(test_name ${file})

  add_test(
    NAME ${test_name}
    COMMAND ${TOIT_EXE_HW} ${toit_file}
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    CONFIGURATIONS pi hw
    )

  set_tests_properties(${test_name} PROPERTIES TIMEOUT 40)
  # Don't run pi tests in parallel with other tests.
  # This can be changed as long as:
  # - resource-locking is added.
  # - the Raspberry Pi is replaced with a more powerful version.
  set_tests_properties(${test_name} PROPERTIES RUN_SERIAL TRUE)
endforeach()
