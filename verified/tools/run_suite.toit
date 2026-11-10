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
Differential test of the reference interpreter (verified/spec) against the
  C++ VM on the repository's test suite.

For every tests/NAME-test.toit and tests/regress/NAME-test.toit (plus the
  -test-slow and -test-force variants) the driver

1. compiles the test to a snapshot (old format) and, with `--format 2`,
  also to a revised-format snapshot (`-Xbytecode_format=2`),
2. dumps the snapshot with tools/spec_dump.toit,
3. runs the dump on the reference interpreter (64-bit smis). A run that
  ends in an unimplemented primitive is *not runnable* and counted per
  primitive; a run that exceeds the step limit is counted as too long,
4. runs the snapshot on the C++ VM and compares stdout and the exit code
  with the interpreter's (64-bit and 32-bit smis, and with the verified
  step disabled).

Tests run like ctest runs them: from the repository root with the
  arguments `foo bar gee` and TOIT_TEST_ENV_ENTRY set.

Usage: toit run verified/tools/run_suite.toit -- [--format 1|2|both] [--jobs N]
  [--max-steps N] [--timeout S] [--filter SUBSTRING]... [--out DIR] [--no-32]
  [--unverified] [--json FILE] [--status FILE]
*/

import cli
import encoding.json
import fs
import host.file

import .harness

/**
Tests whose output depends on timing or object identity even when two VM
  runs happen to agree.
*/
NONDETERMINISTIC ::= {
  "tests/rpc-test.toit": "prints the measured time per RPC",
  "tests/block-test.toit": "prints identity hash codes",
}

main args:
  command := cli.Command "run_suite"
      --help="""
        Differential test of the reference interpreter against the C++ VM
        on the repository's test suite.
        """
      --options=[
        cli.OptionEnum "format" ["1", "2", "both"] --default="1"
            --help="The bytecode format(s) to test.",
        cli.OptionInt "jobs" --default=cpu-count
            --help="The number of tests run in parallel.",
        cli.OptionInt "max-steps" --default=200_000_000
            --help="The step limit of the reference interpreter.",
        cli.OptionInt "timeout" --default=300
            --help="The time limit of a run in seconds.",
        cli.Option "filter" --multi
            --help="Only tests whose path contains this string.",
        cli.Option "out" --default=(fs.join SPEC-CRATE "target/suite")
            --help="The output directory.",
        cli.Flag "32" --default=true
            --help="Also run with 32-bit smis (--no-32 disables it).",
        cli.Flag "unverified" --default=false
            --help="Also run with the verified step disabled.",
        cli.Option "json"
            --help="Write the results as JSON to this file.",
        cli.Option "status"
            --help="Write one line per test and format: format status test [detail].",
      ]
      --run=:: | invocation/cli.Invocation |
        exit (run-suite invocation)
  command.run args

class Options:
  out/string
  dumper/string
  max-steps/int
  timeout/int
  skip-32/bool
  unverified/bool

  constructor --.out --.dumper --.max-steps --.timeout --.skip-32 --.unverified:

run-suite invocation/cli.Invocation -> int:
  out := absolute invocation["out"]
  json-path := invocation["json"]
  status-path := invocation["status"]
  if json-path: json-path = absolute json-path
  if status-path: status-path = absolute status-path
  enter-repo
  make-dirs (fs.join out "f1")
  cargo-build SPEC-CRATE
  dumper := fs.join out "spec_dump.snapshot"
  compile-dumper dumper
  options := Options
      --out=out
      --dumper=dumper
      --max-steps=invocation["max-steps"]
      --timeout=invocation["timeout"]
      --skip-32=not invocation["32"]
      --unverified=invocation["unverified"]
  format := invocation["format"]
  formats := format == "both" ? [1, 2] : [int.parse format]
  tests := discover invocation["filter"]
  results := []
  formats.do: | fmt |
    parallel-do tests --jobs=invocation["jobs"]
        --work=:: | test | run-one test fmt options
        --done=:: | test index result/Map |
          results.add result
          status := result["status"]
          if status == "fail" or status == "dump-error" or status == "load":
            detail := result.contains "detail" ? python-str result["detail"] : ""
            print "FAIL f$fmt $result["test"] $detail"
  formats.do: | fmt |
    print-summary fmt (results.filter: it["format"] == fmt)
  if status-path:
    sorted := results.sort: | a b |
      a["test"].compare-to b["test"] --if-equal=: a["format"].compare-to b["format"]
    lines := ["# Generated by verified/tools/run_suite.toit --status: format, status, test, detail.\n"]
    sorted.do: | r/Map |
      detail := r.get "detail"
      suffix := (detail != null and detail != "") ? " $detail" : ""
      lines.add "$r["format"] $r["status"] $r["test"]$suffix\n"
    write-file status-path (lines.join "")
  if json-path:
    write-file json-path (json-pretty results --indent=1 --sort-keys)
  return (results.any: it["status"] == "fail") ? 1 : 0

/** Python's `str` of a detail value: null prints as "None". */
python-str value -> string:
  return value == null ? "None" : "$value"

print-summary fmt/int rs/List -> none:
  counts := {:}
  rs.do: | r | counts[r["status"]] = (counts.get r["status"] --if-absent=: 0) + 1
  prims := {:}
  rs.do: | r |
    if r["status"] == "unimplemented":
      prims[r["detail"]] = (prims.get r["detail"] --if-absent=: 0) + 1
  runnable := rs.filter: it["status"] == "pass" or it["status"] == "fail"
  print ""
  print "format $fmt: $rs.size tests discovered"
  (counts.keys.sort).do: | k |
    print "  $(pad-right k 14) $counts[k]"
  print "  runnable: $runnable.size, passed: $(counts.get "pass" --if-absent=: 0), failed: $(counts.get "fail" --if-absent=: 0)"
  steps := 0
  vsteps := 0
  runnable.do: | r |
    steps += r.get "steps" --if-absent=: 0
    vsteps += r.get "verified_steps" --if-absent=: 0
  print "  steps on runnable tests: $steps (verified: $vsteps)"
  print "  unimplemented primitives (tests blocked):"
  // Most common first; ties in the order first seen (Counter.most_common).
  names := prims.keys
  order := {:}
  names.size.repeat: order[names[it]] = it
  names.sort --in-place: | a b |
    prims[b].compare-to prims[a] --if-equal=: order[a].compare-to order[b]
  (names[..min 25 names.size]).do: | p |
    print "    $(pad-left "$prims[p]" 4) $(python-str p)"
  fails := (rs.filter: it["status"] == "fail").map: it["test"]
  fails.sort --in-place
  if not fails.is-empty:
    print "  failing: $(fails.join " ")"

/** Runs one test in format $fmt and returns its result. */
run-one test/string fmt/int options/Options -> Map:
  name := (test.replace --all "/" "_")
  name = name[..name.size - 5]
  base := fs.join options.out "f$fmt" name
  make-dirs (fs.dirname base)
  result := {"test": test, "format": fmt}
  // The C++ VM always runs the old format.
  vm-snapshot := fs.join options.out "f1" "$(name).snapshot"
  snapshot := "$(base).snapshot"
  command := fmt == 1
      ? [toit-bin, "compile", "--snapshot", "-o", snapshot, test]
      : [toit-compile-bin, "-Xbytecode_format=2", "-w", snapshot, test]
  r := run command --timeout-s=300 --environment=TEST-ENV --out-path="$(base).compile"
  if r.code != 0:
    result["status"] = "compile-error"
    return result
  if fmt != 1 and not exists vm-snapshot:
    command = [toit-bin, "compile", "--snapshot", "-o", vm-snapshot, test]
    r = run command --timeout-s=300 --environment=TEST-ENV
    if r.code != 0:
      result["status"] = "compile-error"
      return result
  command = [toit-bin, "run", options.dumper, "--", snapshot, "$(base).dump"]
  r = run command --timeout-s=300 --environment=TEST-ENV --out-path="$(base).dumplog"
  if r.code != 0:
    result["status"] = "dump-error"
    result["detail"] = last-runes r.stderr-string 300
    return result
  dump := "$(base).dump"
  r64 := spec-run dump 64 [] options "$(base).spec64"
  kind-detail := classify-spec r64
  kind := kind-detail[0]
  detail := kind-detail[1]
  steps := steps-of r64.stderr-string
  result["steps"] = steps[0]
  result["verified_steps"] = steps[1]
  if kind == "unimplemented" or kind == "steplimit" or kind == "timeout" or kind == "load":
    result["status"] = kind
    result["detail"] = detail
    return result
  vm-path := fs.join options.out "f1" "$(name).vm"
  vm-command := [toit-bin, "run", vm-snapshot, "--"] + TEST-ARGS
  if fmt == 1 or not exists "$(vm-path).out":
    r = run vm-command --timeout-s=options.timeout --environment=TEST-ENV --out-path=vm-path
    write-file "$(vm-path).rc" r.code-string
  vm-out := file-bytes "$(vm-path).out"
  vm-rc := read-file "$(vm-path).rc"
  failures := []
  if not (r64.stdout == vm-out and r64.code-string == vm-rc):
    failures.add "64"
  runs := []
  if not options.skip-32: runs.add [32, []]
  if options.unverified: runs.add [64, ["--no-verified"]]
  runs.do: | entry |
    bits := entry[0]
    extra := entry[1]
    tag := "$bits$(extra.is-empty ? "" : "u")"
    rr := spec-run dump bits extra options "$(base).spec$tag"
    expected-out := vm-out
    exp32 := fs.join REPO "$(test[..test.size - 5]).expected32"
    if bits == 32 and exists exp32: expected-out = file-bytes exp32
    if not (rr.stdout == expected-out and rr.code-string == vm-rc):
      failures.add tag
  if NONDETERMINISTIC.contains test:
    result["status"] = "nondeterministic"
    result["detail"] = NONDETERMINISTIC[test]
    return result
  if not failures.is-empty:
    // Tests whose output depends on timing, addresses or the environment
    // are not comparable: run the VM again and see whether it agrees with
    // itself.
    r2 := run vm-command --timeout-s=options.timeout --environment=TEST-ENV --out-path="$(vm-path)2"
    if not (r2.stdout == vm-out and r2.code-string == vm-rc):
      result["status"] = "nondeterministic"
      return result
  result["status"] = failures.is-empty ? "pass" : "fail"
  if not failures.is-empty:
    result["detail"] = failures.join ","
    result["spec_kind"] = kind
    result["spec_detail"] = detail
  return result

file-bytes path/string -> ByteArray:
  return file.read-contents path

/**
Runs the reference interpreter on $dump with $bits bits per smi. The C++ VM
  reports the snapshot path it was started with as the program name, so the
  interpreter is given the path of the format-1 snapshot.
*/
spec-run dump/string bits/int extra/List options/Options out-path/string -> RunResult:
  name := fs.join ((fs.dirname dump).replace --all "/f2" "/f1") "$((fs.basename dump)[..(fs.basename dump).size - 5]).snapshot"
  command := [SPEC-RUNNER, "--word-bits", "$bits", "--max-steps", "$options.max-steps", "--stats",
              "--program-name", name] + extra + [dump, "--"] + TEST-ARGS
  return run command --timeout-s=options.timeout --environment=TEST-ENV --out-path=out-path

/** The kind of a reference-interpreter run and its detail (or null). */
classify-spec r/RunResult -> List:
  text := r.stderr-string
  prim := word-after text "unimplemented primitive "
  if prim: return ["unimplemented", prim]
  if text.contains "StepLimit": return ["steplimit", null]
  if r.timed-out: return ["timeout", null]
  stuck := word-after text "[spec] stuck: "
  if stuck: return ["stuck", stuck]
  if text.contains "cannot load": return ["load", null]
  return ["ran", null]

/** The steps and verified steps the interpreter reported with --stats. */
steps-of text/string -> List:
  from := 0
  while true:
    at := text.index-of "steps: " from
    if at < 0: return [0, 0]
    from = at + 1
    pos := at + 7
    steps := digits-at text pos
    if not steps: continue
    pos += steps.size
    marker := ", verified steps: "
    if not (text[pos..].starts-with marker): continue
    verified := digits-at text (pos + marker.size)
    if not verified: continue
    return [int.parse steps, int.parse verified]

/** The non-empty run of digits at $pos in $text, or null. */
digits-at text/string pos/int -> string?:
  end := pos
  while end < text.size and text[end] != null and '0' <= text[end] <= '9': end++
  return end == pos ? null : text[pos..end]

/**
The first non-empty run of non-whitespace characters right after an
  occurrence of $prefix in $text (the regular expression `prefix(\S+)`), or
  null.
*/
word-after text/string prefix/string -> string?:
  from := 0
  while true:
    at := text.index-of prefix from
    if at < 0: return null
    from = at + 1
    start := at + prefix.size
    end := start
    while end < text.size and not is-space text[end]: end++
    if end > start: return text[start..end]

is-space c/int? -> bool:
  return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0b or c == 0x0c

/** The last $n characters of $s. */
last-runes s/string n/int -> string:
  count := 0
  i := s.size
  while i > 0 and count < n:
    i--
    if s[i] != null: count++
  return s[i..]
