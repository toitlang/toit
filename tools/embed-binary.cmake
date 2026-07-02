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

# Generates a C++ source file that embeds a binary file as a byte array,
# replacing `xxd -i`. It uses only CMake built-ins, so there is no dependency on
# an external tool and no requirement on the C++ standard or compiler version.
#
# The whole file is converted in a single `string(REGEX REPLACE)` pass. Do not
# be tempted to loop over the bytes: a per-byte `foreach` is orders of magnitude
# slower and makes this unusable on real (~MB) snapshots.
#
# Arguments (passed with -D):
#   SYMBOL: Name of the generated array. The size is stored in `${SYMBOL}_len`.
#   INPUT:  Path to the binary file to embed.
#   OUTPUT: Path of the C++ source file to generate.
#
# The generated symbols match what `xxd -i <file>` produced, so the existing
# `extern` declarations keep working unchanged.

foreach (var SYMBOL INPUT OUTPUT)
  if (NOT DEFINED ${var})
    message(FATAL_ERROR "embed-binary.cmake: missing required argument '${var}'")
  endif()
endforeach()

file(READ "${INPUT}" hex HEX)
string(LENGTH "${hex}" hex_length)
math(EXPR length "${hex_length} / 2")
string(REGEX REPLACE "([0-9a-f][0-9a-f])" "0x\\1," bytes "${hex}")

file(WRITE "${OUTPUT}" "\
// Generated file - do not edit.
unsigned char ${SYMBOL}[] = { ${bytes} };
unsigned int ${SYMBOL}_len = ${length};
")
