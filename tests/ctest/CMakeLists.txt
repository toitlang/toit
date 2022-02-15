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

file(GLOB CC_FILES "*.cc")
file(GLOB CC_TESTS "*_test.cc")
file(GLOB TOIT_TESTS "*_test.toit")

set(CTEST_DIR ${CMAKE_BINARY_DIR}/ctest)

if (APPLE)
  set(LN_FORCE "F")
else()
  set(LN_FORCE "Tf")
endif()

include(fail.cmake)

add_custom_command(
  OUTPUT ${CTEST_DIR}/lib
  COMMAND ln -s${LN_FORCE} ${TOIT_SDK_SOURCE_DIR}/lib ${CTEST_DIR}/lib
  VERBATIM
)

add_custom_target(
    generate-ctest-lib-symlink
    DEPENDS ${CTEST_DIR}/lib
    )

foreach(file ${CC_FILES})
  if("${file}" IN_LIST TOIT_SKIP_TESTS)
    continue()
  endif()
  get_filename_component(exe ${file} NAME_WE)
  add_executable(
    ${exe}
    ${file}
  )

  set_target_properties(${exe} PROPERTIES RUNTIME_OUTPUT_DIRECTORY ${CTEST_DIR})
  add_dependencies(${exe} generate-ctest-lib-symlink)

  target_link_libraries(
    ${exe}
    ${TOIT_LINK_LIBS}
  )

  # Make sure the test is built before we run the tests.
  add_dependencies(check ${exe})
  add_dependencies(check_slow ${exe})
endforeach()

foreach(file ${CC_TESTS})
  if("${file}" IN_LIST TOIT_SKIP_TESTS)
    continue()
  endif()
  file(RELATIVE_PATH test_name ${PROJECT_SOURCE_DIR} ${file})
  get_filename_component(exe ${file} NAME_WE)
  string(REGEX REPLACE "_test.cc$" "_input.toit" test_input ${file})
  add_test(NAME ${test_name} COMMAND ${CTEST_DIR}/${exe} ${test_input})
  set_tests_properties(${test_name} PROPERTIES TIMEOUT 40)
  # Make sure the test is built before we run the tests.
  add_dependencies(check ${exe})
  add_dependencies(check_slow ${exe})
endforeach()

foreach(file ${TOIT_TESTS})
  file(RELATIVE_PATH test_name ${PROJECT_SOURCE_DIR} ${file})
  add_test(NAME
    ${test_name}
    COMMAND $<TARGET_FILE:toit.run> ${file} ${CTEST_DIR})

  set_tests_properties(${test_name} PROPERTIES TIMEOUT 40)
  # Make sure the test is built before we run the tests.
  add_dependencies(check ${exe})
  add_dependencies(check_slow ${exe})
endforeach()

foreach(test ${TOIT_FAILING_TESTS})
  set_tests_properties(${test} PROPERTIES WILL_FAIL TRUE)
endforeach()
