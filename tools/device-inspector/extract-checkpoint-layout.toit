// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import encoding.json
import fs
import host.file
import host.pipe

import .checkpoints

SYMBOLS ::= [
  ARM-SYMBOL,
  HIT-SYMBOL,
  REQUESTED-SYMBOL,
  CURRENT-SYMBOL,
  CONTEXT-SYMBOL,
]

main args/List:
  if args.size != 3:
    print "Usage: extract-checkpoint-layout GDB FIRMWARE.elf OUTPUT.json"
    throw "INVALID_ARGUMENTS"
  extract-checkpoint-layout args[0] args[1] args[2]

extract-checkpoint-layout gdb/string elf/string output/string -> none:
  commands := [gdb, "-nx", "-q", "-batch", elf, "-ex", "set language c++"]
  symbol-index := 0
  SYMBOLS.do: | symbol/string |
    commands.add "-ex"
    commands.add "echo TOIT_CHECKPOINT\t$symbol-index\\n"
    commands.add "-ex"
    commands.add "p/x (unsigned long)&$symbol"
    symbol-index++
  CHECKPOINT-SPECS.do: | spec/Map |
    commands.add "-ex"
    commands.add "echo TOIT_CHECKPOINT\t$symbol-index\\n"
    commands.add "-ex"
    commands.add "p/x (unsigned int)$(spec["enum"])"
    symbol-index++
  values := parse-output (pipe.backticks commands)
  symbols := {:}
  symbol-index = 0
  SYMBOLS.do: | symbol/string |
    value/string? := values.get symbol-index.to-string
    if not value: throw "CHECKPOINT_SYMBOL_MISSING: $symbol"
    parsed := parse-natural value
    symbols[symbol] = "0x$(parsed.to-string --radix=16)"
    symbol-index++
  checkpoint-layouts := []
  CHECKPOINT-SPECS.do: | spec/Map |
    value/string? := values.get symbol-index.to-string
    if not value: throw "CHECKPOINT_ENUM_MISSING: $(spec["enum"])"
    checkpoint-layouts.add {
      "name": spec["name"],
      "id": parse-natural value,
    }
    symbol-index++
  result := {
    "format": LAYOUT-FORMAT,
    "format-version": LAYOUT-VERSION,
    "source": fs.basename elf,
    "pointer-size": 4,
    "byte-order": "little",
    "checkpoints": checkpoint-layouts,
    "symbols": symbols,
  }
  file.write-contents --path=output ((json.encode result) + #[10])

parse-output output/string -> Map:
  values := {:}
  active/string? := null
  normalized := output.replace --all "\r" ""
  normalized.split "\n": | raw/string |
    line := raw.trim
    if line.starts-with "TOIT_CHECKPOINT\t":
      active = line[16..]
    else if active and line.starts-with "\$" and line.contains "=":
      equals := line.index-of "="
      values[active] = line[equals + 1..].trim
      active = null
  return values

parse-natural value/string -> int:
  return value.starts-with "0x"
      ? int.parse --radix=16 value[2..]
      : int.parse value
