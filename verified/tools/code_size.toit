// Copyright (C) 2026 Toit contributors.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

/**
Measures the code size of the two bytecode formats on the three system
  snapshots embedded in the host SDK (compiled with -O2 like the build does)
  and on a fixed set of test programs.

For every program and format it reports the bytecode bytes (headers
  included), the method-body bytes, the header bytes (everything else in the
  bytecodes, including the 4-byte tag of format 2), the class-check table
  (format 2 puts receiver ranges there, format note 15), and the size of the
  program snapshot (the `snapshot` member of the snapshot bundle, without the
  source map).

Usage: toit run verified/tools/code_size.toit [-- [--out DIR] [--json FILE] [--formats 1,2]]
*/

import cli
import fs
import host.file

import .dump_file
import .harness

SYSTEM ::= [
  ["toit", "tools/toit.toit", "tools/.packages-bootstrap", ["-O2"]],
  ["toit_run", "system/extensions/host/toit.run.toit", "system/extensions/host/.packages-bootstrap", ["-O2"]],
  ["run_image", "system/extensions/host/run-image.toit", "system/extensions/host/.packages-bootstrap", ["-O2"]],
]

TESTS ::= [
  "tests/map-test.toit",
  "tests/deque-test.toit",
  "tests/byte-array-test.toit",
  "tests/encoding-test.toit",
  "tests/ble-advertisement-test.toit",
  "tests/is-as-many-test.toit",
  "tests/format-test.toit",
  "tests/string-slice-test.toit",
  "tests/coap-tcp-client-test.toit",
  "tests/constructor-super-test.toit",
]

main args:
  command := cli.Command "code_size"
      --help="Measures the code size of the two bytecode formats."
      --options=[
        cli.Option "out" --default=(fs.join SPEC-CRATE "target/code-size")
            --help="The directory for the snapshots and dumps.",
        cli.Option "json" --help="Also write the results to this JSON file.",
        cli.Option "formats" --default="1,2" --help="The formats to measure.",
      ]
      --run=:: run-code-size it
  command.run args

/** The size of the member $member of the ar archive at $path. */
ar-member-size path/string member/string -> int:
  data := file.read-contents path
  if data[..8].to-string != "!<arch>\n": throw "not an ar archive: $path"
  at := 8
  while at < data.size:
    name := data[at..at + 16].to-string.trim
    while name.ends-with "/": name = name[..name.size - 1]
    size := int.parse data[at + 48..at + 58].to-string.trim
    if name == member: return size
    at += 60 + size + (size & 1)
  throw "no member $member in $path"

dump-stats dump/string -> Map:
  stats := {"bodies": 0, "methods": 0}
  lines := dump-lines dump
  for i := 0; i < lines.size; i++:
    parts := lines[i].split " "
    if parts[0] == "bytecodes":
      stats["bytecodes"] = int.parse parts[1]
    else if parts[0] == "m":
      stats["bodies"] += int.parse parts[2]
      stats["methods"] += 1
    else if parts[0] == "class_check_ids":
      stats["class_check_bytes"] = 2 * (int.parse parts[1])
      break
  stats["headers"] = stats["bytecodes"] - stats["bodies"]
  return stats

measure name/string source/string packages/string? flags/List format/int out/string dumper/string -> Map:
  base := fs.join out "$(name).f$format"
  environment := packages ? {"TOIT_PACKAGE_CACHE_PATHS": fs.join REPO packages} : null
  run-checked [toit-compile-bin] + flags + ["-Xbytecode_format=$format", "-w", "$(base).snapshot", source]
      --environment=environment
  run-checked [toit-bin, "run", dumper, "--", "$(base).snapshot", "$(base).dump"]
  stats := dump-stats "$(base).dump"
  stats["snapshot"] = ar-member-size "$(base).snapshot" "snapshot"
  stats["program"] = name
  stats["format"] = format
  return stats

run-code-size invocation/cli.Invocation -> none:
  out := absolute invocation["out"]
  json-path/string? := invocation["json"]
  if json-path: json-path = absolute json-path
  enter-repo
  make-dirs out
  dumper := fs.join out "spec_dump.snapshot"
  compile-dumper dumper
  formats := (invocation["formats"].split ",").map: int.parse it
  programs := SYSTEM + (TESTS.map: [(fs.basename it)[..(fs.basename it).size - 5], it, null, []])
  results := []
  programs.do: | program |
    formats.do: | format |
      results.add (measure program[0] program[1] program[2] program[3] format out dumper)
  print "$(pad-right "program" 24) $(pad-left "fmt" 3) $(pad-left "bytecodes" 9) $(pad-left "bodies" 9) $(pad-left "headers" 8) $(pad-left "methods" 7) $(pad-left "cc-tab" 6) $(pad-left "snapshot" 9)"
  results.do: | r |
    print "$(pad-right r["program"] 24) $(pad-left "$r["format"]" 3) $(pad-left "$r["bytecodes"]" 9) $(pad-left "$r["bodies"]" 9) $(pad-left "$r["headers"]" 8) $(pad-left "$r["methods"]" 7) $(pad-left "$r["class_check_bytes"]" 6) $(pad-left "$r["snapshot"]" 9)"
  formats.do: | format |
    rs := results.filter: it["format"] == format
    sum := : | key | rs.reduce --initial=0: | acc r | acc + r[key]
    print "total f$format: bytecodes $(sum.call "bytecodes"), bodies $(sum.call "bodies"), headers $(sum.call "headers"), snapshot $(sum.call "snapshot")"
  if json-path:
    write-file json-path (json-pretty results --indent=1 --sort-keys)
