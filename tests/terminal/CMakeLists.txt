# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by an MIT-style license that can be
# found in the lib/LICENSE file.

if(UNIX)
  add_executable(terminal-test-runner terminal-test-runner-posix.cc)
  find_library(TERMINAL_UTIL_LIBRARY util)
  if(TERMINAL_UTIL_LIBRARY)
    target_link_libraries(terminal-test-runner PRIVATE ${TERMINAL_UTIL_LIBRARY})
  endif()
elseif(WIN32)
  add_executable(terminal-test-runner terminal-test-runner-win.cc)
endif()

if(TARGET terminal-test-runner)
  add_dependencies(build_test_assets terminal-test-runner)

  add_test(
    NAME tests/terminal/terminal-test
    COMMAND terminal-test-runner
        $<TARGET_FILE:toit.run>
        ${CMAKE_CURRENT_SOURCE_DIR}/terminal-test.toit
  )
  set_tests_properties(
    tests/terminal/terminal-test
    PROPERTIES TIMEOUT 15
  )
endif()
