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

file(GLOB TESTS RELATIVE "${TOIT_SDK_SOURCE_DIR}" "*-test.toit")

foreach(file ${TESTS})
  if("${file}" IN_LIST TOIT_SKIP_TESTS)
    continue()
  endif()

  add_test(
    NAME "${file}"
    COMMAND "$<TARGET_FILE:toit.run>" "${TOIT_SDK_SOURCE_DIR}/${file}"
        "$<TARGET_FILE:toit>"
        "${TOIT_SDK_SOURCE_DIR}"
    )
  set_tests_properties(${file} PROPERTIES TIMEOUT 300)
endforeach()
