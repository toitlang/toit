// Copyright (C) 2025 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

main args:
  if args.size == 3 and args[0] == "RUN_TEST":
    is-stdout := args[1] == "STDOUT"
    test-case := int.parse args[2]
    run-spawned --is-stdout=is-stdout test-case
    return

  throw "UNEXPECTED ARGUMENTS"

TESTS ::= [
  "",
  "foo",
  "foo\nbar",
]

run-spawned test-case/int --is-stdout/bool -> none:
  if is-stdout:
    print_ TESTS[test-case]
  else:
    print-on-stderr_ TESTS[test-case]
