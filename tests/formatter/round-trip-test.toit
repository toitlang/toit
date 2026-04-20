// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Formats every .toit file under lib/ and asserts idempotence (permanent
// invariant). Verbatim equality with the input no longer holds — the
// formatter canonicalizes spacing and indentation — so we only check that
// a second format produces the same output as the first.
//
// We don't run `toit analyze` on the formatted file as a secondary check:
// copying to a tmp dir breaks relative imports and would produce false
// positives. A corrupting bug in the formatter has two ways to show up
// here anyway — either the formatter crashes, or idempotence fails
// because the broken output triggers a different format path on the
// second pass.

import expect show *
import host.directory
import host.file

import ..toit.utils

check-format toit-exe/ToitExecutable src-path/string label/string:
  toit-exe.backticks ["format", src-path]
  once := (file.read-contents src-path).to-string
  toit-exe.backticks ["format", src-path]
  twice := (file.read-contents src-path).to-string

  if once != twice:
    print "IDEMPOTENCE FAILURE ($label)"
    expect false --message="formatter not idempotent on $label"

// Walks `dir` recursively and calls `block` with every .toit file path.
walk-toit-files dir/string [block]:
  stream := directory.DirectoryStream dir
  try:
    while entry := stream.next:
      if entry == "." or entry == "..": continue
      path := "$dir/$entry"
      if file.is-directory path:
        walk-toit-files path block
      else if path.ends-with ".toit":
        block.call path
  finally:
    stream.close

main args:
  toit-exe := ToitExecutable args
  if args.size < 2:
    print "usage: round-trip-test.toit <toit-exe> <repo-root>"
    exit 1
  repo-root := args[1]
  lib-root := "$repo-root/lib"

  with-tmp-dir: | tmp-dir/string |
    count := 0
    walk-toit-files lib-root: | source-path/string |
      relative := source-path[(lib-root.size + 1)..]
      tmp-path := "$tmp-dir/$(relative.replace --all "/" "_")"
      contents := file.read-contents source-path
      file.write-contents --path=tmp-path contents
      check-format toit-exe tmp-path relative
      count++
    print "round-trip-test: $count files OK"
