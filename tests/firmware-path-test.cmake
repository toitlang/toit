# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

# Checks resolve_file from the ESP-IDF Toit component. Run with
#   cmake -DTEST_DIRECTORY=<absolute temporary directory> -P firmware-path-test.cmake

include(${CMAKE_CURRENT_LIST_DIR}/../toolchains/idf/components/toit/resolve_file.cmake)
if(NOT IS_ABSOLUTE "${TEST_DIRECTORY}")
    message(FATAL_ERROR "Pass an absolute temporary TEST_DIRECTORY")
endif()
set(CMAKE_HOME_DIRECTORY "${TEST_DIRECTORY}/application")
set(repository "${TEST_DIRECTORY}/repository")
file(MAKE_DIRECTORY "${CMAKE_HOME_DIRECTORY}" "${repository}/system")
file(WRITE "${repository}/system/boot.toit" "fixture")
file(WRITE "${repository}/both.toit" "repository fixture")
file(WRITE "${CMAKE_HOME_DIRECTORY}/both.toit" "application fixture")
file(WRITE "${CMAKE_HOME_DIRECTORY}/with spaces.toit" "space fixture")

function(check input expected)
    resolve_file(actual "${input}" "${repository}" "")
    if(NOT actual STREQUAL expected)
        message(FATAL_ERROR "${input}: expected ${expected}, got ${actual}")
    endif()
endfunction()
check("system/boot.toit" "${repository}/system/boot.toit")
check("system" "${repository}/system")
check("both.toit" "${CMAKE_HOME_DIRECTORY}/both.toit")
check("with spaces.toit" "${CMAKE_HOME_DIRECTORY}/with spaces.toit")
check("${repository}/both.toit" "${repository}/both.toit")
check("missing.toit" "${repository}/missing.toit")
check("${TEST_DIRECTORY}/absolute-missing.toit" "${TEST_DIRECTORY}/absolute-missing.toit")
message(STATUS "firmware-path-test: all checks passed")
