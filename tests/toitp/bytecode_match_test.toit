// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import host.file
import ...tools.snapshot

parse_bytecodes bytes:
  str := bytes.to_string
  lines := str.split "\n"
  lines.map --in_place: it.trim
  lines.filter --in_place: it != ""
  return lines.map: | line/string |
    space := line.index_of " "
    name := line[..space]
    size := int.parse line[space + 1..space + 2]
    format_space := line.index_of " " (space + 3)
    format := line[space + 3..format_space]
    description := line[format_space + 1..]
    [name, size, format, description]

main args:
  c_bytecode_list := parse_bytecodes (file.read_content args[0])
  expect_equals BYTE_CODES.size c_bytecode_list.size
  used_c_formats := {}
  format_mapping := {:}
  BYTE_CODES.size.repeat:
    toit_bytecode /Bytecode := BYTE_CODES[it]
    c_bytecode := c_bytecode_list[it]
    if not format_mapping.contains toit_bytecode.format:
      format_mapping[toit_bytecode.format] = c_bytecode[2]
      expect_not (used_c_formats.contains c_bytecode[2])
      used_c_formats.add c_bytecode[2]
    expect_equals toit_bytecode.name c_bytecode[0]
    expect_equals toit_bytecode.size c_bytecode[1]
    expect_equals format_mapping[toit_bytecode.format] c_bytecode[2]
    expect_equals toit_bytecode.description c_bytecode[3]
