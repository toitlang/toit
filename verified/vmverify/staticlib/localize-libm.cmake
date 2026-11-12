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

# Copies the device library (libtoit_rust.a) with the C math functions of
# Rust's compiler_builtins (sin, pow, fmod, floor, ...: weak definitions,
# a port of musl's libm) made local, so that the firmware links newlib's
# libm for them, as without the core.
#
# Without this the linker takes compiler_builtins' weak definitions, since
# the Rust archive comes before libm: the C++ primitives (math.pow, sin,
# the float formatting) then ran Rust's versions, which were 5.7 KB larger
# on the classic ESP32 (fmod alone 2.5 KB plus a 2.6 KB 128-bit division)
# and can differ from newlib in the last bit. The Rust code's own calls
# (floor, ceil, trunc, sqrt, fmod) are undefined references in the core's
# object and resolve to libm. The memory and soft-float helpers stay: the
# ROM's (memcpy, __adddf3, ...) win over them anyway.
#
# With -DLOOP_IN_IRAM=ON (Kconfig TOIT_VERIFIED_CORE_LOOP_IN_IRAM) it also
# renames the sections of the core's run loop (`step::run_loop`: its code
# and, on Xtensa, its literals to .iram1.*, its jump table to .dram1.*), so
# that ESP-IDF's linker script places them in IRAM and DRAM, as
# CONFIG_TOIT_INTERPRETER_IN_IRAM does for the C++ interpreter. On the
# hardware the loop running from flash thrashes the flash cache: on the
# classic ESP32 the json benchmark took 1.84 s from flash and 0.48 s from
# IRAM (format 1 / C++: 0.36 s); docs/format2-migration.md, "Devices:
# hardware results".
#
# Usage: cmake -DNM=... -DOBJCOPY=... [-DOBJDUMP=... -DLOOP_IN_IRAM=ON]
#              -DINPUT=in.a -DOUTPUT=out.a -P localize-libm.cmake

execute_process(
  COMMAND "${NM}" "${INPUT}"
  OUTPUT_VARIABLE nm_output
  ERROR_QUIET
  RESULT_VARIABLE nm_result)
if (NOT nm_result EQUAL 0)
  message(FATAL_ERROR "${NM} ${INPUT} failed")
endif()
string(REPLACE "\n" ";" nm_lines "${nm_output}")
set(symbols)
foreach (line IN LISTS nm_lines)
  # Weak definitions with a C name that is not a compiler helper (__*) or a
  # memory function.
  if (line MATCHES " W ([a-z][a-z0-9_]*)$")
    set(name "${CMAKE_MATCH_1}")
    if (NOT name MATCHES "^(memcmp|memcpy|memmove|memset|bcmp|strlen)$")
      list(APPEND symbols "${name}")
    endif()
  endif()
endforeach()
list(REMOVE_DUPLICATES symbols)
set(args)
foreach (name IN LISTS symbols)
  list(APPEND args "--localize-symbol=${name}")
endforeach()
if (LOOP_IN_IRAM)
  execute_process(
    COMMAND "${OBJDUMP}" -h "${INPUT}"
    OUTPUT_VARIABLE objdump_output
    ERROR_QUIET
    RESULT_VARIABLE objdump_result)
  if (NOT objdump_result EQUAL 0)
    message(FATAL_ERROR "${OBJDUMP} -h ${INPUT} failed")
  endif()
  string(REPLACE "\n" ";" objdump_lines "${objdump_output}")
  set(loop_text_found FALSE)
  foreach (line IN LISTS objdump_lines)
    # The Rust (v0) mangled name of toit_verified_core::step::run_loop.
    if (line MATCHES " (\\.(text|literal|rodata|srodata)\\.[^ ]*18toit_verified_core4step8run_loop) ")
      set(section "${CMAKE_MATCH_1}")
      set(kind "${CMAKE_MATCH_2}")
      if (kind STREQUAL "text")
        list(APPEND args "--rename-section=${section}=.iram1.toit_run_loop")
        set(loop_text_found TRUE)
      elseif (kind STREQUAL "literal")
        list(APPEND args "--rename-section=${section}=.iram1.toit_run_loop.literal")
      else()
        list(APPEND args "--rename-section=${section}=.dram1.toit_run_loop")
      endif()
    endif()
  endforeach()
  if (NOT loop_text_found)
    message(FATAL_ERROR "LOOP_IN_IRAM: no section of step::run_loop in ${INPUT}")
  endif()
endif()
execute_process(
  COMMAND "${OBJCOPY}" ${args} "${INPUT}" "${OUTPUT}.tmp"
  RESULT_VARIABLE objcopy_result)
if (NOT objcopy_result EQUAL 0)
  message(FATAL_ERROR "${OBJCOPY} failed on ${INPUT}")
endif()
file(RENAME "${OUTPUT}.tmp" "${OUTPUT}")
