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
Replaces a literal text in a file, in place, for the mutants of
  verified/cxx/annotated/mutant.sh (a reverted bug fix is applied to a copy
  of the C++ source and to a copy of its sidecar alike).

Usage: toit run text_replace.toit -- FILE FROM TO [FROM TO]...
FROM must occur exactly once in FILE (else exit status 1: a mutant that
  no longer applies must not pass silently). `\n` in FROM and TO is a
  newline. `ANCHOR@@TEXT` as FROM: ANCHOR must occur exactly once, and the
  first TEXT after it is replaced (for a line that occurs in several
  functions).
*/

import host.file

main args:
  if args.size < 3 or args.size % 2 != 1:
    print "usage: text_replace.toit FILE FROM TO [FROM TO]..."
    exit 2
  path := args[0]
  text := (file.read-contents path).to-string
  for i := 1; i < args.size; i += 2:
    from := args[i].replace --all "\\n" "\n"
    to := args[i + 1].replace --all "\\n" "\n"
    at := from.index-of "@@"
    if at >= 0:
      anchor := from[..at]
      from = from[at + 2..]
      start := text.index-of anchor
      if start < 0 or (text.index-of anchor (start + 1)) >= 0:
        print "text_replace: the anchor `$anchor` occurs $(start < 0 ? "not" : "more than once") in $path"
        exit 1
      first := text.index-of from start
      if first < 0:
        print "text_replace: `$from` does not occur after `$anchor` in $path"
        exit 1
      text = text[..first] + to + text[first + from.size..]
      continue
    first := text.index-of from
    if first < 0 or (text.index-of from (first + 1)) >= 0:
      print "text_replace: `$from` occurs $(first < 0 ? "not" : "more than once") in $path"
      exit 1
    text = text[..first] + to + text[first + from.size..]
  file.write-contents text --path=path
