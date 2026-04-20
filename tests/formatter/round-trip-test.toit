// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Mirrors lib/ into a tmp directory (preserving structure so relative
// imports still resolve in case we ever want to re-add an analyze
// check), formats every .toit file in place, and asserts idempotence:
// running format twice produces the same bytes as running it once.
//
// Verbatim equality with the input no longer holds (the formatter
// canonicalizes spacing and indentation), so we don't check that.
//
// A real semantic safety net (structural AST equivalence between input
// and output) is still pending — see PLAN.md's Tier 3.

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

// Recursively mirrors `src-dir` to `dst-dir`, copying file contents
// verbatim. Creates intermediate directories as needed.
mirror-tree src-dir/string dst-dir/string:
  directory.mkdir --recursive dst-dir
  stream := directory.DirectoryStream src-dir
  try:
    while entry := stream.next:
      if entry == "." or entry == "..": continue
      src-path := "$src-dir/$entry"
      dst-path := "$dst-dir/$entry"
      if file.is-directory src-path:
        mirror-tree src-path dst-path
      else:
        file.write-contents --path=dst-path (file.read-contents src-path)
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
    mirror-tree lib-root "$tmp-dir/lib"
    count := 0
    walk-toit-files "$tmp-dir/lib": | src-path/string |
      relative := src-path[(tmp-dir.size + 1)..]
      check-format toit-exe src-path relative
      count++
    print "round-trip-test: $count files OK"
