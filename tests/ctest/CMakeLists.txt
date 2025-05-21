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
  OUTPUT ${CTEST_DIR}/lib/toit/lib
  COMMAND ln -s${LN_FORCE} ${TOIT_SDK_SOURCE_DIR}/lib ${CTEST_DIR}/lib/toit/lib
  VERBATIM
)

set(ORIGINAL_BOOT_SNAPSHOT ${PROJECT_BINARY_DIR}/generated/toit_run_snapshot.cc)
set(BOOT_SNAPSHOT ${CMAKE_CURRENT_BINARY_DIR}/toit_run_snapshot.cc)

add_custom_command(
  OUTPUT ${BOOT_SNAPSHOT}
  COMMAND ${CMAKE_COMMAND} -E copy ${ORIGINAL_BOOT_SNAPSHOT} ${BOOT_SNAPSHOT}
  DEPENDS build_boot_snapshot
  VERBATIM
)

add_custom_target(
    generate-ctest-lib-symlink
    DEPENDS ${CTEST_DIR}/lib/toit/lib
    )

set(NEGATIVE_TESTS)

foreach(file ${CC_FILES};${C_FILES})
  file(READ ${file} content)
  string(FIND "${content}" "// NEGATIVE-TEST" FOUND_POSITION)

  if (FOUND_POSITION EQUAL -1)
    continue()
  endif()

  list(APPEND NEGATIVE_TESTS ${file})
endforeach()

foreach(MODE positive negative)
  foreach(file ${CC_FILES};${C_FILES})

    set(IS_NEGATIVE_TEST FALSE)
    if(${MODE} STREQUAL "negative")
      if (NOT ${file} IN_LIST NEGATIVE_TESTS)
        continue()
      endif()
      set(IS_NEGATIVE_TEST TRUE)
    endif()

    get_filename_component(exe ${file} NAME_WE)
    if (${IS_NEGATIVE_TEST})
      set(exe ${exe}-negative)
    endif()

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

    if (IS_NEGATIVE_TEST)
      target_compile_definitions(${exe} PRIVATE NEGATIVE_TEST)
    endif()

    set_target_properties(${exe} PROPERTIES RUNTIME_OUTPUT_DIRECTORY ${CTEST_DIR})
    add_dependencies(${exe} generate-ctest-lib-symlink)

    target_link_libraries(
      ${exe}
      ${TOIT_LINK_LIBS}
    )

    add_dependencies(build_test_assets ${exe})

    if (NOT ${file} IN_LIST C_TESTS AND NOT ${file} IN_LIST CC_TESTS)
      continue()
    endif()

    file(RELATIVE_PATH test_name ${PROJECT_SOURCE_DIR} ${file})

    if(${IS_NEGATIVE_TEST})
      set(test_name "${test_name}-negative")
    endif()

    if("${test_name}" IN_LIST TOIT_SKIP_TESTS)
      continue()
    endif()

    set(TEST_EXPECTATION_NAME "${test_name}")
    if("${test_name}" IN_LIST TOIT_FAILING_TESTS)
      set(TEST_EXPECTATION_NAME "${test_name}-expected-to-fail")
    endif()

    set(WRAPPER)
    if (IS_NEGATIVE_TEST)
      # Ctest only supports negative exit codes, but not aborts, segfaults, ...
      # Wrap the test in a script that converts aborts to exit code 1.
      if (WIN32)
        set(WRAPPER powershell -ExecutionPolicy Bypass -File "${CMAKE_CURRENT_SOURCE_DIR}/abort-wrapper.ps1")
      else()
        set(WRAPPER "${CMAKE_CURRENT_SOURCE_DIR}/abort-wrapper.sh")
      endif()
    endif()

    string(REGEX REPLACE "-test.cc?$" "-input.toit" test_input ${file})
    add_test(
      NAME ${TEST_EXPECTATION_NAME}
      COMMAND ${WRAPPER} ${CTEST_DIR}/${exe} ${test_input}
    )
    set_tests_properties(${TEST_EXPECTATION_NAME} PROPERTIES TIMEOUT 40)
    if (IS_NEGATIVE_TEST)
      set_tests_properties(${TEST_EXPECTATION_NAME} PROPERTIES WILL_FAIL TRUE)
    endif()
    add_dependencies(build_test_assets ${exe})

    if("${test_name}" IN_LIST TOIT_FAILING_TESTS)
      if (IS_NEGATIVE_TEST)
        set_tests_properties(${TEST_EXPECTATION_NAME} PROPERTIES WILL_FAIL FALSE)
      else()
        set_tests_properties(${TEST_EXPECTATION_NAME} PROPERTIES WILL_FAIL TRUE)
      endif()
    endif()
  endforeach()
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
