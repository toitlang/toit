// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Runs the formatter in TOIT_FORMAT_FLAT_TEST=1 mode over every .toit
// file under lib/ and asserts two things:
//   1. The formatter's on-every-format AST-equivalence check accepts
//      the output (no "formatter changed meaning" aborts).
//   2. A second format produces the same bytes as the first
//      (idempotence, the permanent invariant).
//
// Unlike round-trip-test (which runs in normal mode and checks the same
// two properties on the preserving path), this test exercises the
// paren-insertion rules at scale — in flat mode the formatter actually
// rewrites most statement-position expressions.

import expect show *
import host.directory
import host.file
import host.os

import ..toit.utils

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
    print "usage: flat-dogfood-test.toit <toit-exe> <repo-root>"
    exit 1
  repo-root := args[1]
  lib-root := "$repo-root/lib"

  os.env["TOIT_FORMAT_FLAT_TEST"] = "1"

  with-tmp-dir: | tmp-dir/string |
    mirror-tree lib-root "$tmp-dir/lib"
    count := 0
    walk-toit-files "$tmp-dir/lib": | src-path/string |
      relative := src-path[(tmp-dir.size + 1)..]
      // Format writes on success; refuses (exit 1) when ast_equivalent
      // rejects. Fork surfaces the exit code for us to see.
      first := toit-exe.fork ["format", src-path]
      if first.exit-code != 0:
        print "FLAT FORMAT REJECTED ($relative):"
        print first.stderr
        expect false --message="flat-mode AST mismatch on $relative"
      once := (file.read-contents src-path).to-string

      second := toit-exe.fork ["format", src-path]
      if second.exit-code != 0:
        print "FLAT SECOND FORMAT REJECTED ($relative)"
        expect false --message="flat-mode second format rejected on $relative"
      twice := (file.read-contents src-path).to-string

      if once != twice:
        print "FLAT IDEMPOTENCE FAILURE ($relative)"
        expect false --message="flat-mode not idempotent on $relative"
      count++
    print "flat-dogfood-test: $count files OK"
