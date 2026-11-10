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
Runs the programs the reference interpreter can run untrusted in format 2.

run_suite.toit classifies every test of the suite
  (verified/spec/tests/suite-status.txt); a format-2 test whose status is
  `pass` or `steplimit` uses only primitives the reference interpreter
  implements (the allowed set). Each of them runs

- in format 1, trusted, on the C++ interpreter (`toit.run test`), and
- in format 2, as an untrusted container on the verified core
  (`toit.run --untrusted test`, which compiles to format 2),

like ctest runs them (from the repository root, arguments `foo bar gee`,
  TOIT_TEST_ENV_ENTRY set). Stdout and the exit code must be identical.

Usage: toit run verified/tools/untrusted_suite.toit -- [--jobs N]
  [--status FILE] [--filter S] [--out DIR]
*/

import cli
import fs

import .harness

RUN ::= fs.join REPO "build/host/sdk/lib/toit/bin/toit.run"
STATUS ::= fs.join SPEC-CRATE "tests/suite-status.txt"
/** The test environment, without a format override. */
ENVIRONMENT ::= {"TOIT_TEST_ENV_ENTRY": "TOIT_TEST_ENV_VALUE", "TOIT_BYTECODE_FORMAT": null}

main args:
  command := cli.Command "untrusted_suite"
      --help="""
        Runs the suite programs the reference interpreter can run in format
        2 trusted in format 1 and untrusted in format 2 and compares them.
        """
      --options=[
        cli.OptionInt "jobs" --default=8
            --help="The number of tests run in parallel.",
        cli.Option "status" --default=STATUS
            --help="The status file of run_suite.toit.",
        cli.Option "filter"
            --help="Only tests whose path contains this string.",
        cli.Option "out" --default=(fs.join REPO "build/untrusted-suite")
            --help="The output directory.",
      ]
      --run=:: | invocation/cli.Invocation |
        exit (untrusted-suite invocation)
  command.run args

untrusted-suite invocation/cli.Invocation -> int:
  status-path := absolute invocation["status"]
  out := absolute invocation["out"]
  filter := invocation["filter"]
  enter-repo
  tests := {:}
  (split-lines (read-file status-path)).do: | line/string |
    if line.starts-with "#": continue.do
    parts := (line.split " ").filter: it != ""
    if parts[0] != "2": continue.do
    tests[parts[2]] = parts[1]
  selected := (tests.keys.filter: tests[it] == "pass" or tests[it] == "steplimit").sort
  if filter: selected = selected.filter: it.contains filter
  make-dirs out
  outcomes := parallel-map selected --jobs=invocation["jobs"]:: | test |
    r1 := run ([RUN, test] + TEST-ARGS) --timeout-s=300 --environment=ENVIRONMENT
    r2 := run ([RUN, "--untrusted", test] + TEST-ARGS) --timeout-s=300 --environment=ENVIRONMENT
    [r1, r2]
  results := []
  different := []
  selected.size.repeat: | i |
    test := selected[i]
    r1/RunResult := outcomes[i][0]
    r2/RunResult := outcomes[i][1]
    same := r1.code == r2.code and r1.stdout == r2.stdout
    results.add {"test": test, "status": tests[test], "same": same, "rc1": r1.code, "rc2": r2.code}
    if not same:
      base := fs.join out (test.replace --all "/" "_")
      write-file "$(base).f1.out" r1.stdout
      write-file "$(base).f2.out" r2.stdout
      write-file "$(base).f2.err" r2.stderr
      print "DIFF $test (exit $r1.code vs $r2.code)"
      different.add test
  excluded := {:}
  statuses := {}
  tests.values.do: statuses.add it
  (statuses.to-list.sort).do: | s |
    if s != "pass" and s != "steplimit":
      excluded[s] = (tests.values.filter: it == s).size
  counts := {
    "selected": selected.size,
    "identical": (results.filter: it["same"]).size,
    "different": different,
    "excluded": excluded,
  }
  write-file (fs.join out "results.json") (json-pretty {"summary": counts, "results": results} --indent=2)
  print (json-pretty counts --indent=2)
  return different.is-empty ? 0 : 1
