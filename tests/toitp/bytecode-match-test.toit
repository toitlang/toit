// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import host.file
import ...tools.snapshot

parse-bytecodes bytes:
  str := bytes.to-string
  lines := str.split "\n"
  lines.map --in-place: it.trim
  lines.filter --in-place: it != ""
  return lines.map: | line/string |
    space := line.index-of " "
    name := line[..space]
    size := int.parse line[space + 1..space + 2]
    format-space := line.index-of " " (space + 3)
    format := line[space + 3..format-space]
    description := line[format-space + 1..]
    [name, size, format, description]

main args:
  c-bytecode-list := parse-bytecodes (file.read-contents args[0])
  expect-equals BYTE-CODES.size c-bytecode-list.size
  used-c-formats := {}
  format-mapping := {:}
  BYTE-CODES.size.repeat:
    toit-bytecode /Bytecode := BYTE-CODES[it]
    c-bytecode := c-bytecode-list[it]
    if not format-mapping.contains toit-bytecode.format:
      format-mapping[toit-bytecode.format] = c-bytecode[2]
      expect-not (used-c-formats.contains c-bytecode[2])
      used-c-formats.add c-bytecode[2]
    expect-equals toit-bytecode.name c-bytecode[0]
    expect-equals toit-bytecode.size c-bytecode[1]
    expect-equals format-mapping[toit-bytecode.format] c-bytecode[2]
    expect-equals toit-bytecode.description c-bytecode[3]
