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
End-to-end fuzzer for the verified core (verified/core/DESIGN.md,
  "Fuzzing").

For every seed program the driver

1. compiles it to a format-2 snapshot (TOIT_BYTECODE_FORMAT=2),
2. asks toit.run for the raw bytecodes and their coverage (instruction
  starts and operand bytes) and locates the bytecodes in the snapshot,
3. applies one mutation per mutant: a random opcode byte, or an operand
  byte set to a random or boundary value (0x00, 0x01, 0x7f, 0x80, 0xff),
4. keeps the mutants the verified structural verifier accepts. The
  default filter (--filter=launch) is the VM's own launch-time
  verification: the mutant is launched as an untrusted container
  (`toit.run --untrusted`) on the sanitizer build, the VM builds the
  abstract program from its memory and runs the verifier
  (verified/vmverify), and a refusal (VERIFICATION_FAILED,
  INVALID_SNAPSHOT) counts as rejected. --filter=spec uses the external
  path instead (tools/spec_dump.toit and `toit_spec_verify`), and
  --filter=loader `toit.run --verify`,
5. runs each kept mutant as an untrusted container
  (`toit.run --untrusted`) on a sanitizer build with a time limit and
  classifies the outcome (with --filter=launch, steps 4 and 5 are the
  same run).

Besides instruction bytes, a tenth of the mutations hit the other bytes of
  the bytecodes (method headers), which the VM's header decoder and the
  verifier must reject or handle.

A panic of the verifier inside the VM ("verifier failure") rejects the
  program but is a bug: it is kept as a finding.

A crash is a run that ends by a signal or prints an AddressSanitizer or
  UndefinedBehaviorSanitizer report. Everything else (normal exit, Toit
  exception, the core's "stuck state" termination, a timeout) is fine.

Mutants are deterministic per seed and index (a SplitMix64 generator
  seeded with seed * 1000003 + index), so `--seed S --start I --count 1`
  reproduces mutant I. (The mutants differ from those of the earlier
  Python driver, whose generator was Python's.)

Usage: toit run verified/tools/core_fuzz.toit -- [--seconds N] [--seed N]
  [--start N] [--count N] [--jobs N] [--timeout S] [--out DIR] [--run PATH]
  [--check-run PATH] [--toit PATH] [--spec-verify PATH]
  [--filter launch|spec|loader] [programs...]

--run is the toit.run that runs the mutants (default: build/asan, falling
  back to build/host); --check-run the one that compiles and checks them
  (default: build/host). Results go to DIR (default build/fuzz):
  summary.json and, for every crash, the mutant snapshot and its output.
*/

import cli
import fs
import host.directory
import host.file
import host.pipe
import monitor

import .harness

DEFAULT-SEEDS ::= [
  "tests/sandbox/cli/print-main.toit",
  "tests/block-test.toit",
  "tests/lambda-test.toit",
  "tests/try-finally-test.toit",
  "tests/exception-test.toit",
  "tests/string-test.toit",
  "tests/list-test.toit",
  "tests/map-test.toit",
  "tests/class-id-test.toit",
  "tests/non-local-branch-test.toit",
  "tests/task-test.toit",
]

BOUNDARY ::= [0x00, 0x01, 0x7f, 0x80, 0xff]
ENVIRONMENT ::= {"TOIT_BYTECODE_FORMAT": "2", "TOIT_TEST_ENV_ENTRY": "TOIT_TEST_ENV_VALUE"}

/**
Outcomes that are kept for inspection: crashes are bugs; a stuck state or
  a refusal of a program the verified verifier accepted is a disagreement
  between the verifier and the core or its loader, and a verifier panic a
  bug of the verifier. Timeouts are only counted (mutants may loop
  forever).
*/
FINDINGS ::= ["crash", "stuck", "refused", "verifier-panic"]

FILTERS ::= {
  "launch": "the VM's launch-time verification (toit.run --untrusted, verified/vmverify)",
  "spec": "toit_spec_verify (verified check::verify, untrusted rules)",
  "loader": "toit.run --verify",
}

main args:
  asan := fs.join REPO "build/asan/sdk/lib/toit/bin/toit.run"
  host := fs.join REPO "build/host/sdk/lib/toit/bin/toit.run"
  command := cli.Command "core_fuzz"
      --help="End-to-end fuzzer for the verified core."
      --options=[
        cli.OptionInt "seconds" --default=300
            --help="Stop starting mutants after this many seconds.",
        cli.OptionInt "seed" --default=1
            --help="The seed of the mutations.",
        cli.OptionInt "start" --default=0
            --help="The first mutant index (mutants are deterministic per seed and index).",
        cli.OptionInt "count" --default=0
            --help="Stop after this many mutants (0: only --seconds limits).",
        cli.OptionInt "jobs" --default=8
            --help="The number of mutants run in parallel.",
        cli.OptionInt "timeout" --default=10
            --help="The time limit of a mutant's run in seconds.",
        cli.Option "out" --default=(fs.join REPO "build/fuzz")
            --help="The output directory.",
        cli.Option "run" --default=(exists asan ? asan : host)
            --help="The toit.run that runs the mutants.",
        cli.Option "check-run" --default=host
            --help="The toit.run that compiles and checks the mutants.",
        cli.Option "toit" --default=(fs.join REPO "build/host/sdk/bin/toit")
            --help="The toit executable (for --filter=spec).",
        cli.Option "spec-verify" --default=(fs.join SPEC-CRATE "target/release/toit_spec_verify")
            --help="The toit_spec_verify executable (for --filter=spec).",
        cli.OptionEnum "filter" ["launch", "spec", "loader"] --default="launch"
            --help="How mutants are checked before they run.",
      ]
      --rest=[
        cli.Option "programs" --multi
            --help="The seed programs (relative to the repository root).",
      ]
      --run=:: | invocation/cli.Invocation |
        exit (fuzz invocation)
  command.run args

class Config:
  run/string
  check-run/string
  toit/string
  spec-verify/string
  filter/string
  seed/int
  timeout/int
  out/string
  work/string

  constructor --.run --.check-run --.toit --.spec-verify --.filter --.seed --.timeout --.out --.work:

/** A compiled seed program. */
class Prepared:
  name/string
  data/ByteArray
  offset/int
  coverage/ByteArray
  /** Positions of header bytes (coverage 0). */
  headers/List
  /** Positions of instruction bytes (coverage 1 or 2). */
  instructions/List

  constructor .name .data .offset .coverage:
    headers = []
    instructions = []
    coverage.size.repeat: | i |
      c := coverage[i]
      if c == 0: headers.add i
      else if c == 1 or c == 2: instructions.add i

/** SplitMix64. */
class Random:
  state_/int := ?

  constructor seed/int:
    state_ = seed

  next -> int:
    state_ += 0x9e3779b97f4a7c15
    z := state_
    z = (z ^ (z >>> 30)) * 0xbf58476d1ce4e5b9
    z = (z ^ (z >>> 27)) * 0x94d049bb133111eb
    return z ^ (z >>> 31)

  /** A float in [0, 1). */
  next-float -> float:
    return (next >>> 11).to-float / 9007199254740992.0  // 2^53.

  /** An int in [0, n). */
  next-int n/int -> int:
    return (next >>> 1) % n

  choice list/List -> any:
    return list[next-int list.size]

fuzz invocation/cli.Invocation -> int:
  out := absolute invocation["out"]
  make-dirs out
  work := directory.mkdtemp "$out/tmp"
  config := Config
      --run=(absolute invocation["run"])
      --check-run=(absolute invocation["check-run"])
      --toit=(absolute invocation["toit"])
      --spec-verify=(absolute invocation["spec-verify"])
      --filter=invocation["filter"]
      --seed=invocation["seed"]
      --timeout=invocation["timeout"]
      --out=out
      --work=work
  enter-repo
  try:
    return fuzz-in config invocation
  finally:
    directory.rmdir --recursive --force work

fuzz-in config/Config invocation/cli.Invocation -> int:
  seeds := invocation["programs"]
  if seeds.is-empty: seeds = DEFAULT-SEEDS
  prepared := []
  seeds.do: | seed |
    if exists (fs.join REPO seed):
      p := prepare seed config
      if p: prepared.add p
  if prepared.is-empty:
    pipe.stderr.out.write "no seeds\n"
    return 2
  jobs := invocation["jobs"]
  first := invocation["start"]
  count := invocation["count"]
  seconds := invocation["seconds"]
  counts := {:}
  crashes := []
  start := Time.monotonic-us
  index := first
  more := :
    (count == 0 or index < first + count)
        and (Time.monotonic-us - start) < seconds * 1_000_000
  finished := monitor.Channel (2 * jobs)
  in-flight := 0
  while more.call or in-flight > 0:
    while more.call and in-flight < 2 * jobs:
      mutant := index
      task::
        result := null
        exception := catch --trace:
          result = fuzz-one config prepared mutant
        finished.send (result or ["?", "?", "error: $exception"])
      index++
      in-flight++
    entry := finished.receive
    in-flight--
    outcome := entry[2]
    counts[outcome] = (counts.get outcome --if-absent=: 0) + 1
    if FINDINGS.contains outcome:
      print "$outcome.to-ascii-upper $entry[0]: $entry[1]"
    if outcome == "crash":
      crashes.add "$entry[0]: $entry[1]"
  seed-names := prepared.map: it.name
  summary := {
    "seconds": (Time.monotonic-us - start + 500_000) / 1_000_000,
    "seed": config.seed,
    "run": config.run,
    "filter": FILTERS[config.filter],
    "seeds": seed-names,
    "first": first,
    "mutants": index - first,
    "outcomes": counts,
    "crashes": crashes,
  }
  write-file (fs.join config.out "summary.json") (json-pretty summary --indent=2)
  print (json-pretty summary --indent=2)
  return crashes.is-empty ? 0 : 1

/** Compiles a seed and finds its bytecodes; null if that fails. */
prepare seed/string config/Config -> Prepared?:
  name := (fs.basename seed).replace --all ".toit" ""
  snap := fs.join config.work "$(name).snapshot"
  r := run [config.check-run, "-w", snap, seed] --timeout-s=300 --environment=ENVIRONMENT
  if r.code != 0:
    pipe.stderr.out.write "skip $seed: compilation failed ($r.code)\n"
    return null
  bytecodes-file := fs.join config.work "$(name).bytecodes"
  coverage-file := fs.join config.work "$(name).coverage"
  r1 := run [config.check-run, "--verify", "-q", "--emit-bytecodes=$bytecodes-file", snap] --timeout-s=60 --environment=ENVIRONMENT
  r2 := run [config.check-run, "--verify", "-q", "--emit-coverage=$coverage-file", snap] --timeout-s=60 --environment=ENVIRONMENT
  if r1.code != 0 or r2.code != 0:
    pipe.stderr.out.write "skip $seed: cannot emit bytecodes or coverage\n"
    return null
  data := file.read-contents snap
  bytecodes := file.read-contents bytecodes-file
  coverage := file.read-contents coverage-file
  offset := find-bytes data bytecodes 0
  if offset < 0 or (find-bytes data bytecodes (offset + 1)) >= 0:
    pipe.stderr.out.write "skip $seed: bytecodes not found exactly once in the snapshot\n"
    return null
  return Prepared name data offset coverage

/** The first index at or after $from where $needle occurs in $data, or -1. */
find-bytes data/ByteArray needle/ByteArray from/int -> int:
  if needle.is-empty: return from <= data.size ? from : -1
  first := needle[0]
  i := from
  while i + needle.size <= data.size:
    i = data.index-of first --from=i --to=(data.size - needle.size + 1)
    if i < 0: return -1
    if data[i..i + needle.size] == needle: return i
    i++
  return -1

/** One mutant of $p: [mutant bytes, description]. */
mutate rng/Random p/Prepared -> List:
  positions := rng.next-float < 0.1 ? p.headers : p.instructions
  i := positions.is-empty ? (rng.next-int p.coverage.size) : (rng.choice positions)
  value/int := ?
  kind/string := ?
  c := p.coverage[i]
  if c == 0:
    value = rng.next-float < 0.5 ? (rng.choice BOUNDARY) : (rng.next-int 256)
    kind = "header"
  else if c == 1:
    value = rng.next-int 256
    kind = "opcode"
  else:
    value = rng.next-float < 0.5 ? (rng.choice BOUNDARY) : (rng.next-int 256)
    kind = "operand"
  mutant := p.data.copy
  old := p.data[p.offset + i]
  if old == value: value ^= 0x01
  mutant[p.offset + i] = value
  return [mutant, "$kind bci $i: 0x$(%02x old) -> 0x$(%02x value)"]

/** The outcome of a mutant's run. */
classify r/RunResult -> string:
  text := r.stdout-string + r.stderr-string
  if text.contains "ERROR: AddressSanitizer" or text.contains "runtime error:": return "crash"
  if r.timed-out: return "timeout"
  if r.code < 0: return "crash"
  if text.contains "stuck state": return "stuck"
  if text.contains "verifier failure" or text.contains "panicked": return "verifier-panic"
  if text.contains "FORMAT_2_REQUIRED" or text.contains "VERIFICATION_FAILED" or text.contains "INVALID_SNAPSHOT":
    return "refused"
  return "exit-$r.code"

/** Creates, checks and runs mutant $index: [seed name, description, outcome]. */
fuzz-one config/Config prepared/List index/int -> List:
  rng := Random config.seed * 1_000_003 + index
  p/Prepared := prepared[index % prepared.size]
  mutated := mutate rng p
  description := mutated[1]
  path := fs.join config.work "m$(index).snapshot"
  write-file path mutated[0]
  if config.filter == "launch":
    r := run [config.run, "--untrusted", path] --timeout-s=config.timeout --environment=ENVIRONMENT
    outcome := classify r
    if outcome == "refused":
      file.delete path
      return [p.name, description, "rejected"]
    return keep-finding config path index p.name description outcome r
  accepted := false
  if config.filter == "spec":
    dump := "$(path).dump"
    r := run [config.toit, "run", fs.join REPO "tools/spec_dump.toit", "--", path, dump] --timeout-s=60 --environment=ENVIRONMENT
    if r.code == 0:
      r = run [config.spec-verify, "--quiet", dump] --timeout-s=60 --environment=ENVIRONMENT
      accepted = r.code == 0 and (r.stdout-string + r.stderr-string).starts-with "accepted"
    if exists dump: file.delete dump
  else:
    r := run [config.check-run, "--verify", "-q", path] --timeout-s=30 --environment=ENVIRONMENT
    accepted = r.code == 0
  if not accepted:
    file.delete path
    return [p.name, description, "rejected"]
  r := run [config.run, "--untrusted", path] --timeout-s=config.timeout --environment=ENVIRONMENT
  return keep-finding config path index p.name description (classify r) r

/** Keeps the mutant and its output if $outcome is a finding. */
keep-finding config/Config path/string index/int name/string description/string outcome/string r/RunResult -> List:
  if FINDINGS.contains outcome:
    keep := fs.join config.out "$outcome-$(index).snapshot"
    file.rename path keep
    write-file "$(keep).txt" (("$name: $description\n".to-byte-array + r.stdout) + r.stderr)
  else:
    file.delete path
  return [name, description, outcome]
