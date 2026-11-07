# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
if(UNIX)
  find_package(Python3 COMPONENTS Interpreter QUIET)
  if(Python3_FOUND)
    add_test(NAME tests/storage-recovery
      COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/recovery.py"
        $<TARGET_FILE:toit.run>)
    set_tests_properties(tests/storage-recovery PROPERTIES TIMEOUT 120)
  endif()
endif()
