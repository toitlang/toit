# Copyright (C) 2026 Toit contributors.
# Use of this source code is governed by a Zero-Clause BSD license that can
# be found in the tests/LICENSE file.

# Writes a C++ file that provides the snapshot in the format the vessels use:
# The size of the snapshot in four little-endian bytes, followed by the snapshot.

file(READ "${SNAPSHOT}" HEX HEX)
string(LENGTH "${HEX}" HEX_LENGTH)
math(EXPR SIZE "${HEX_LENGTH} / 2")

set(PREFIX "")
foreach(SHIFT 0 8 16 24)
  math(EXPR BYTE "(${SIZE} >> ${SHIFT}) & 255")
  string(APPEND PREFIX "${BYTE},")
endforeach()

string(REGEX REPLACE "([0-9a-f][0-9a-f])" "0x\\1," BYTES "${HEX}")
file(WRITE "${OUTPUT}" "unsigned char vessel_snapshot_data[] = {${PREFIX}${BYTES}};\n")
