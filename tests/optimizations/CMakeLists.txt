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

file(GLOB TOIT_OPTIMIZATION_TESTS RELATIVE ${TOIT_SDK_SOURCE_DIR} "*_test.toit")

include(fail.cmake)

foreach(file ${TOIT_OPTIMIZATION_TESTS})
  if("${file}" IN_LIST TOIT_SKIP_TESTS)
    continue()
  endif()

  add_test(
    NAME ${file}
    COMMAND $<TARGET_FILE:toit.run> ${TOIT_SDK_SOURCE_DIR}/${file} $<TARGET_FILE:toit.run> ${TOIT_SDK_SOURCE_DIR}/tools/lsp/server/server.toit
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    )
  set_tests_properties(${file} PROPERTIES TIMEOUT 40)

  if("${file}" IN_LIST TOIT_FAILING_TESTS)
    set_tests_properties(${file} PROPERTIES WILL_FAIL TRUE)
  endif()
endforeach()
