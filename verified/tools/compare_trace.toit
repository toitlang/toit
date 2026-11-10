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
Compares the bytecode trace of the debug VM (`toit.run -Xtrace`) with the
  reference interpreter's (`toit-spec-run --trace-bci`), instruction by
  instruction.

The debug VM prints `[<absolute bci>] <bytecode>` for every bytecode it
  dispatches, for all processes of the VM (run on a single scheduler
  thread), and a `[yield from interpretation]`/`[preempted from
  interpretation]`/`[exit interpretation ...]` line whenever a process
  leaves the interpreter. The trace is cut into
  segments at those lines. The program's process runs in segments whose
  bcis continue the reference interpreter's trace; segments of the system
  process (a different program) are skipped. Within a matching segment
  every bci must agree.

Usage: toit run verified/tools/compare_trace.toit -- <program.toit|snapshot>
           [--steps N] [--word-bits 64] [--timeout S] [args...]

The debug VM is TOIT_DEBUG_RUN, by default the toit.run of build/dbg
  (`make BUILD=build/dbg BUILD_TYPE=Debug sdk`).
Prints the number of consecutive steps compared and the first divergence.
*/

import cli
import fs
import host.directory
import host.os

import .dump_file
import .harness

ONE-CORE ::= "int get_nprocs(void) { return 1; }\nint get_nprocs_conf(void) { return 1; }\n"


main arguments:
  command := cli.Command "compare_trace"
      --help="Compares the debug VM's -Xtrace with the reference interpreter's trace."
      --options=[
        cli.OptionInt "steps" --default=20000 --help="Steps of the reference interpreter.",
        cli.OptionInt "word-bits" --default=64 --help="Smi size of the reference interpreter.",
        cli.OptionInt "timeout" --default=600 --help="Time limit of each run in seconds.",
      ]
      --rest=[
        cli.Option "program" --required --help="A .toit program or a snapshot.",
        cli.Option "args" --multi --help="Arguments of the program.",
      ]
      --run=:: compare-trace it
  command.run arguments

debug-run -> string:
  return os.env.get "TOIT_DEBUG_RUN" or (fs.join REPO "build/dbg/host/sdk/lib/toit/bin/toit.run")

compare-trace invocation/cli.Invocation -> none:
  program/string := invocation["program"]
  args/List := invocation["args"]
  steps/int := invocation["steps"]
  bits/int := invocation["word-bits"]
  timeout/int := invocation["timeout"]
  program-path := absolute program
  enter-repo
  tmp := directory.mkdtemp "/tmp/compare_trace-"
  spec := []
  vm := []
  try:
    snapshot := program-path
    if program.ends-with ".toit":
      snapshot = fs.join tmp "p.snapshot"
      run-checked [toit-bin, "compile", "--snapshot", "-o", snapshot, program-path]
    dumper := fs.join tmp "spec_dump.snapshot"
    compile-dumper dumper
    dump := fs.join tmp "p.dump"
    run-checked [toit-bin, "run", dumper, "--", snapshot, dump]
    spec = spec-trace dump args bits steps timeout
    vm = vm-trace snapshot args timeout tmp
  finally:
    directory.rmdir --recursive tmp
  result := compare spec vm opcode-table
  n := result[0]
  switches := result[1]
  div := result[2]
  note := result[3]
  total-vm := (vm.filter: it != null).size
  suffix := div ? "; DIVERGENCE at $div" : (note ? "; $note" : "")
  print "$(fs.basename program): compared $n consecutive steps (spec trace $spec.size steps, VM trace $total-vm steps of all processes, $switches process switches)$suffix"
  exit (div ? 1 : 0)

/** The reference interpreter's trace: a list of [bci, opcode]. */
spec-trace dump/string args/List bits/int max-steps/int timeout/int -> List:
  result := run [SPEC-RUNNER, "--word-bits", "$bits", "--trace-bci", "--max-steps", "$max-steps", dump, "--"] + args
      --timeout-s=timeout
  if result.timed-out: throw "toit-spec-run timed out"
  out := []
  (result.stderr-string.split "\n").do: | line/string |
    if line.starts-with "B ":
      fields := (line[2..].split " ").filter: it != ""
      if fields.size != 2: throw "unexpected trace line: $line"
      out.add [int.parse fields[0], int.parse fields[1]]
  return out

/**
The debug VM's trace as a list of [bci, text] lines and null for "left
  the interpreter" markers.
*/
vm-trace snapshot/string args/List timeout/int tmp/string -> List:
  // The VM starts one scheduler thread per core and the processes' traces
  // would interleave line by line. A one-core get_nprocs keeps the VM on a
  // single scheduler thread.
  src := fs.join tmp "onecore.c"
  lib := fs.join tmp "onecore.so"
  write-file src ONE-CORE
  run-checked ["cc", "-shared", "-fPIC", "-o", lib, src]
  result := run [debug-run, "-Xtrace", snapshot] + args
      --timeout-s=timeout
      --environment={"LD_PRELOAD": lib}
  if result.timed-out: throw "the debug VM timed out"
  out := []
  (result.stdout-string.split "\n").do: | line/string |
    entry := trace-line line
    if entry:
      out.add entry
    else if line.contains "interpretation":
      out.add null
  return out

/** Matches `[<spaces><digits>] ` at the start of $line; returns [bci, rest]. */
trace-line line/string -> List?:
  if not line.starts-with "[": return null
  i := 1
  while i < line.size and (line[i] == ' ' or line[i] == '\t'): i++
  start := i
  while i < line.size and '0' <= line[i] <= '9': i++
  if i == start or not line[i..].starts-with "] ": return null
  return [int.parse line[start..i], line[i + 2..]]

/**
Walks the VM trace, attributing lines to the program while they continue
  the reference interpreter's trace. The VM prints a marker line (null
  here) whenever a process leaves the interpreter, including on
  preemption, so within a segment every line of the program must match;
  after a marker the program must resume exactly where the reference
  interpreter continues. Returns [matched steps, switches, divergence or
  null, note or null].
*/
compare spec/List vm/List table/List -> List:
  same := : | line step |
    line[0] == step[0] and line[1].starts-with table[step[1]][1]
  i := 0
  in-program := false
  switches := 0
  for k := 0; k < vm.size; k++:
    line := vm[k]
    if i >= spec.size: break
    if line == null:
      if in-program: switches++
      in-program = false
      continue
    if same.call line spec[i]:
      in-program = true
      i++
      continue
    if in-program:
      // A branch right after a primitive whose result depends on the
      // outside world (task_has_messages: when the system process's reply
      // arrives) ends the comparison: the oracles differ, not the bytecode
      // semantics.
      recent := spec[(max 0 i - 3)..i].map: table[it[1]][0]
      if (recent.contains "PRIMITIVE") and table[spec[i - 1][1]][0].starts-with "BRANCH":
        return [i, switches, null, "stopped at an environment-dependent primitive result before step $i"]
      prev := i > 0 ? table[spec[i - 1][1]][0] : null
      return [i, switches, "step $i: VM $(py-repr-line line), spec bci $spec[i][0] ($table[spec[i][1]][0]) after $(prev or "None")", null]
  if i < spec.size:
    return [i, switches, "step $i: spec continues at bci $spec[i][0], the VM does not", null]
  return [i, switches, null, null]

/** The trace line [bci, text] as Python prints the tuple (`(12, 'text')`). */
py-repr-line line/List -> string:
  return "($line[0], $(py-repr line[1]))"

/** $s quoted like Python's repr of a string. */
py-repr s/string -> string:
  quote := (s.contains "'") and not (s.contains "\"") ? '"' : '\''
  result := "$(string.from-rune quote)"
  s.do --runes: | c |
    if c == quote or c == '\\': result += "\\$(string.from-rune c)"
    else if c == '\n': result += "\\n"
    else if c == '\r': result += "\\r"
    else if c == '\t': result += "\\t"
    else if c < 0x20 or c == 0x7f: result += "\\x$(%02x c)"
    else: result += string.from-rune c
  return result + (string.from-rune quote)
