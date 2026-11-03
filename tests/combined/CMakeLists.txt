# Copyright (C) 2026 Toit contributors.
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

file(GLOB COMBINED_TESTS RELATIVE "${TOIT_SDK_SOURCE_DIR}" "*-test.toit")

set(SYSTEM_SOURCE "${TOIT_SDK_SOURCE_DIR}/system/extensions/host/toit.run-combined.toit")
set(SYSTEM_PACKAGES "${TOIT_SDK_SOURCE_DIR}/system/extensions/host/.packages-bootstrap")

foreach(file ${COMBINED_TESTS})
  add_test(
    NAME ${file}
    COMMAND $<TARGET_FILE:toit.run> "${TOIT_SDK_SOURCE_DIR}/${file}"
        "${CMAKE_CURRENT_SOURCE_DIR}/input" $<TARGET_FILE:toit.compile> $<TARGET_FILE:toit.run>
        "${SYSTEM_SOURCE}"
  )
  # The system program finds its packages through the cache paths.
  set_tests_properties(${file} PROPERTIES TIMEOUT 40 ENVIRONMENT "TOIT_PACKAGE_CACHE_PATHS=${SYSTEM_PACKAGES}")
endforeach()
