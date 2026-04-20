// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Formats a curated corpus of real Toit sources and asserts idempotence
// (permanent invariant) plus, while the formatter is still verbatim, exact
// byte equality with the input. Remove the verbatim check at M2.

import expect show *
import host.file

import ..toit.utils

CORPUS-SUBPATHS ::= [
  "lib/core/collections.toit",
  "lib/core/string.toit",
  "lib/core/numbers.toit",
  "lib/core/time.toit",
  "lib/core/exceptions.toit",
  "lib/core/objects.toit",
  "lib/core/utils_.toit",
  "lib/expect.toit",
  "lib/bitmap.toit",
  "lib/bytes.toit",
]

check-format toit-exe/ToitExecutable src-path/string label/string:
  original := (file.read-contents src-path).to-string
  toit-exe.backticks ["format", src-path]
  once := (file.read-contents src-path).to-string
  toit-exe.backticks ["format", src-path]
  twice := (file.read-contents src-path).to-string

  if once != twice:
    print "IDEMPOTENCE FAILURE ($label)"
    expect false --message="formatter not idempotent on $label"

  if original != once:
    print "VERBATIM FAILURE ($label)"
    expect false --message="formatter is not verbatim on $label"

main args:
  toit-exe := ToitExecutable args
  if args.size < 2:
    print "usage: round-trip-test.toit <toit-exe> <repo-root>"
    exit 1
  repo-root := args[1]

  with-tmp-dir: | tmp-dir/string |
    CORPUS-SUBPATHS.do: | subpath/string |
      source-path := "$repo-root/$subpath"
      if not file.is-file source-path:
        print "skipping missing corpus file: $subpath"
        continue.do

      tmp-path := "$tmp-dir/$(subpath.replace --all "/" "_")"
      contents := file.read-contents source-path
      file.write-contents --path=tmp-path contents
      check-format toit-exe tmp-path subpath
