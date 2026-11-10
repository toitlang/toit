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
Measures the effect of the format revision on executed instructions and
  code size, over the tests that run_suite found runnable in both formats
  (run it with `--format both --json FILE` first).

Prints the total steps per format, the opcodes whose counts change most,
  and the bytecode size of each format.

Usage: toit run verified/tools/measure.toit -- <suite.json> [--out DIR]

--out is the directory run_suite wrote the dumps to (its --out).
  Opcodes with the same change are listed in name order.
*/

import cli
import encoding.json
import fs
import host.file

import .dump_file
import .harness

GROUPS ::= [
  ["checked field loads", ["LOAD_FIELD", "LOAD_FIELD_WIDE", "LOAD_FIELD_LOCAL", "POP_LOAD_FIELD_LOCAL"]],
  ["unchecked field loads (this)", ["LOAD_FIELD_THIS"]],
  ["checked field stores", ["STORE_FIELD", "STORE_FIELD_WIDE", "STORE_FIELD_POP"]],
  ["unchecked field stores (this)", ["STORE_FIELD_THIS"]],
  ["try/finally setup", ["LINK", "UNLINK", "TRY"]],
  ["intrinsics", ["INTRINSIC_SMI_REPEAT", "INTRINSIC_ARRAY_DO", "INTRINSIC_HASH_FIND", "INTRINSIC_HASH_DO"]],
  ["block calls", ["INVOKE_BLOCK"]],
  ["static calls", ["INVOKE_STATIC", "INVOKE_STATIC_TAIL"]],
  ["returns", ["RETURN", "RETURN_NULL"]],
]

main args:
  command := cli.Command "measure"
      --help="Measures executed instructions and code size of the two formats."
      --options=[
        cli.Option "out" --default=(fs.join SPEC-CRATE "target/suite")
            --help="The output directory of the run_suite run.",
      ]
      --rest=[
        cli.Option "suite-json" --required
            --help="The JSON file of `run_suite --format both --json`.",
      ]
      --run=:: run-measure it
  command.run args

/** The executed opcodes of the program in $dump: opcode name -> count. */
histogram dump/string -> Map:
  result := run [SPEC-RUNNER, "--histogram", "--max-steps", "200000000", dump, "--"] + TEST-ARGS
      --timeout-s=600
  h := {:}
  (result.stderr-string.split "\n").do: | line/string |
    if not line.starts-with "[histogram] ": continue.do
    parts := line[12..].split " "
    if parts.size < 2 or parts[0] == "": continue.do
    digits := parts[1]
    end := 0
    while end < digits.size and '0' <= digits[end] <= '9': end++
    if end == 0: continue.do
    h[parts[0]] = (h.get parts[0] --if-absent=: 0) + (int.parse digits[..end])
  return h

count counts/Map name/string -> int:
  return counts.get name --if-absent=: 0

percent a/int b/int -> string:
  return "$(signed-float 100.0 * (b - a) / a)%"

run-measure invocation/cli.Invocation -> none:
  results := json.decode (file.read-contents invocation["suite-json"])
  out := invocation["out"]
  by := {:}
  results.do: | r |
    (by.get r["test"] --init=: {:})[r["format"]] = r["status"]
  tests := []
  by.do: | test formats |
    if (formats.get 1) == "pass" and (formats.get 2) == "pass": tests.add test
  tests.sort --in-place
  dumps := tests.map: | t/string |
    name := (t.replace --all "/" "_")[..t.size - 5]
    [fs.join out "f1" "$(name).dump", fs.join out "f2" "$(name).dump"]
  totals := [{:}, {:}]
  jobs := []
  dumps.do: | pair |
    jobs.add [pair[0], 0]
    jobs.add [pair[1], 1]
  parallel-do jobs --jobs=16
      --work=:: | job | histogram job[0]
      --done=:: | job index h |
        h.do: | op n | totals[job[1]][op] = (count totals[job[1]] op) + n
  sizes := [0, 0]
  bodies := [0, 0]
  dumps.do: | pair |
    2.repeat:
      sizes[it] += bytecodes-size pair[it]
      bodies[it] += body-size pair[it]
  s1 := totals[0].values.reduce --initial=0: | a b | a + b
  s2 := totals[1].values.reduce --initial=0: | a b | a + b
  print "tests: $tests.size"
  print "steps: format 1 $s1, format 2 $s2 ($(percent s1 s2))"
  print "bytecodes (sum over tests, incl. headers): format 1 $sizes[0], format 2 $sizes[1] ($(percent sizes[0] sizes[1]))"
  print "method bodies only: format 1 $bodies[0], format 2 $bodies[1] ($(percent bodies[0] bodies[1])); headers (and tag): $(sizes[0] - bodies[0]) -> $(sizes[1] - bodies[1]) bytes"
  print "opcode groups (format 1 -> format 2):"
  GROUPS.do: | group |
    g1 := group[1].reduce --initial=0: | a op | a + (count totals[0] op)
    g2 := group[1].reduce --initial=0: | a op | a + (count totals[1] op)
    print "  $(pad-right group[0] 30) $(pad-left "$g1" 12) $(pad-left "$g2" 12)"
  names := {}
  names.add-all totals[0].keys
  names.add-all totals[1].keys
  diff := : | n | ((count totals[1] n) - (count totals[0] n)).abs
  sorted := names.to-list.sort: | a b |
    da := diff.call a
    db := diff.call b
    da != db ? db.compare-to da : a.compare-to b
  print "largest changes in executed opcodes (format 1 -> format 2):"
  sorted[..min 25 sorted.size].do: | n |
    a := count totals[0] n
    b := count totals[1] n
    print "  $(pad-right n 26) $(pad-left "$a" 12) $(pad-left "$b" 12) $(pad-left (signed b - a) 12)"
