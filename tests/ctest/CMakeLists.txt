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
file(GLOB C_FILES "*.c")
file(GLOB C_TESTS "*-test.c")
file(GLOB CC_TESTS "*-test.cc")
file(GLOB TOIT_TESTS "*-test.toit")

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

set(ORIGINAL_BOOT_SNAPSHOT ${PROJECT_BINARY_DIR}/generated/toit.run.snapshot.cc)
set(BOOT_SNAPSHOT ${CMAKE_CURRENT_BINARY_DIR}/toit.run.snapshot.cc)

add_custom_command(
  OUTPUT ${BOOT_SNAPSHOT}
  COMMAND ${CMAKE_COMMAND} -E copy ${ORIGINAL_BOOT_SNAPSHOT} ${BOOT_SNAPSHOT}
  DEPENDS build_boot_snapshot
  VERBATIM
)

add_custom_target(
    generate-ctest-lib-symlink
    DEPENDS ${CTEST_DIR}/lib
    )

foreach(file ${CC_FILES};${C_FILES})
  get_filename_component(exe ${file} NAME_WE)
  if (${file} MATCHES "toit-run-test.c")
    add_executable(
      ${exe}
      ${CMAKE_SOURCE_DIR}/src/toit_run.cc
      ${CMAKE_SOURCE_DIR}/src/run.cc
      ${BOOT_SNAPSHOT}
      ${file}
    )
  else()
    add_executable(
      ${exe}
      ${file}
    )
  endif()

  set_target_properties(${exe} PROPERTIES RUNTIME_OUTPUT_DIRECTORY ${CTEST_DIR})
  add_dependencies(${exe} generate-ctest-lib-symlink)

  target_link_libraries(
    ${exe}
    ${TOIT_LINK_LIBS}
  )

  add_dependencies(build_test_assets ${exe})
endforeach()

foreach(file ${CC_TESTS};${C_TESTS})
  file(RELATIVE_PATH test_name ${PROJECT_SOURCE_DIR} ${file})

  if("${test_name}" IN_LIST TOIT_SKIP_TESTS)
    continue()
  endif()

  set(TEST_EXPECTATION_NAME "${test_name}")
  if("${test_name}" IN_LIST TOIT_FAILING_TESTS)
    set(TEST_EXPECTATION_NAME "${test_name}-expected-to-fail")
  endif()

  get_filename_component(exe ${file} NAME_WE)
  string(REGEX REPLACE "-test.cc?$" "-input.toit" test_input ${file})
  add_test(
    NAME ${TEST_EXPECTATION_NAME}
    COMMAND ${CTEST_DIR}/${exe} ${test_input}
  )
  set_tests_properties(${TEST_EXPECTATION_NAME} PROPERTIES TIMEOUT 40)
  add_dependencies(build_test_assets ${exe})

  if("${test_name}" IN_LIST TOIT_FAILING_TESTS)
    set_tests_properties(${TEST_EXPECTATION_NAME} PROPERTIES WILL_FAIL TRUE)
  endif()
endforeach()

foreach(file ${TOIT_TESTS})
  file(RELATIVE_PATH test_name ${PROJECT_SOURCE_DIR} ${file})

  if("${test_name}" IN_LIST TOIT_SKIP_TESTS)
    continue()
  endif()

  set(TEST_EXPECTATION_NAME "${test_name}")
  if("${test_name}" IN_LIST TOIT_FAILING_TESTS)
    set(TEST_EXPECTATION_NAME "${test_name}-expected-to-fail")
  endif()

  add_test(
    NAME ${TEST_EXPECTATION_NAME}
    COMMAND $<TARGET_FILE:toit.run> ${file} ${CTEST_DIR})

  set_tests_properties(${TEST_EXPECTATION_NAME} PROPERTIES TIMEOUT 40)
  add_dependencies(build_test_assets ${exe})

  if("${test_name}" IN_LIST TOIT_FAILING_TESTS)
    set_tests_properties(${TEST_EXPECTATION_NAME} PROPERTIES WILL_FAIL TRUE)
  endif()
endforeach()
