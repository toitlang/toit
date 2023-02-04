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

# Valgrind only works on Linux.
# Return if we are on any other platform.
if(NOT CMAKE_SYSTEM_NAME STREQUAL "Linux")
  return()
endif()

file(GLOB VALGRIND_TESTS RELATIVE "${CMAKE_CURRENT_SOURCE_DIR}" "*_test.toit")

set(VALGRIND_TEST_DIR ${CMAKE_BINARY_DIR}/valgrind_test)

include("${TOIT_SDK_SOURCE_DIR}/tools/toit.cmake")

set(TOITP_SOURCE "${TOIT_SDK_SOURCE_DIR}/tools/toitp.toit")
set(TOITP_EXE "${CMAKE_CURRENT_BINARY_DIR}/toitp${CMAKE_EXECUTABLE_SUFFIX}")
set(TOITP_DEP "${CMAKE_CURRENT_BINARY_DIR}/toitp.dep")

set(CTEST_DIR ${CMAKE_BINARY_DIR}/ctest)

include(fail.cmake OPTIONAL)

foreach(file ${VALGRIND_TESTS})
  file(RELATIVE_PATH test_name ${PROJECT_SOURCE_DIR} "${CMAKE_CURRENT_SOURCE_DIR}/${file}")

  if("${test_name}" IN_LIST TOIT_SKIP_TESTS)
    continue()
  endif()

  set(input "${CMAKE_CURRENT_SOURCE_DIR}/${file}")
  set(snap ${VALGRIND_TEST_DIR}/${file}.snap)
  set(dep ${VALGRIND_TEST_DIR}/${file}.dep)

  ADD_TOIT_SNAPSHOT(
    ${input}
    ${snap}
    ${dep}
    "")

  set(build_snap tests-valgrind-build_${file})
  add_custom_target(${build_snap} DEPENDS ${snap})

  # Make sure the test input is built before we run the tests.
  add_dependencies(check ${build_snap})
  add_dependencies(check_slow ${build_snap})

  set(valgrind_xml ${VALGRIND_TEST_DIR}/${file}.valgrind.xml)

  add_test(
    NAME ${test_name}
    COMMAND ${CMAKE_COMMAND}
        -DTOITVM=$<TARGET_FILE:toit.run>
        "-DTEST=${snap}"
        "-DVALGRIND_XML=${valgrind_xml}"
        -P "${CMAKE_CURRENT_SOURCE_DIR}/run.cmake"
  )
  set_tests_properties(${test_name} PROPERTIES TIMEOUT 40)

  if("${test_name}" IN_LIST TOIT_FAILING_TESTS)
    set_tests_properties(${test_name} PROPERTIES WILL_FAIL TRUE)
  endif()
endforeach()
