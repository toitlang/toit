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

# Only included when TOIT_BUILD_FUZZERS is set. Use tests/fuzz/build.sh,
# which configures a separate clang build with the sanitizers enabled.

# The boot snapshot is taken from the normal host build: generating it here
# would run the sanitized compiler.
set(TOIT_FUZZ_BOOT_SNAPSHOT_CC "${CMAKE_SOURCE_DIR}/build/host/generated/toit_run_snapshot.cc"
    CACHE FILEPATH "Generated boot snapshot source of a normal host build")

foreach(fuzzer message-decoder snapshot-reader)
  set(target "${fuzzer}-fuzzer")
  add_executable(${target} "${CMAKE_CURRENT_SOURCE_DIR}/${target}.cc" "${TOIT_FUZZ_BOOT_SNAPSHOT_CC}")
  target_link_options(${target} PRIVATE -fsanitize=fuzzer)
  target_link_libraries(${target} ${TOIT_LINK_LIBS})
  set_target_properties(${target} PROPERTIES RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/fuzz")
endforeach()

add_custom_target(build_fuzzers DEPENDS message-decoder-fuzzer snapshot-reader-fuzzer)
