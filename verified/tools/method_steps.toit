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
Attributes the executed instructions of a program to the methods that
  execute them, in both formats, and prints the methods whose counts differ
  most. Used for format note 16 (where the instructions that replace the
  intrinsics go).

With several pairs of dumps it sums the counts and also groups them by the
  intrinsic whose replacement executes them: HASH_FIND (the Toit body of
  `find-body_`), HASH_DO (`hash-do_` and the loops of `Map.do`, `Set.do` and
  their reverse forms and skip helpers, which iterate themselves when
  `hash-do_` returns early), ARRAY_DO (`do_` of the arrays) and SMI_REPEAT
  (`SmallInteger_.repeat`).

Usage: toit run verified/tools/method_steps.toit -- [--top N]
           <f1.dump> <f2.dump> [<f1.dump> <f2.dump>...] [-- args...]

Methods with the same difference are listed in name order.
*/

import host.pipe

import .dump_file
import .harness

main argv/List:
  args := TEST-ARGS
  dash := argv.index-of "--"
  if dash >= 0:
    args = argv[dash + 1..]
    argv = argv[..dash]
  top := 15
  top-at := argv.index-of "--top"
  if top-at >= 0:
    top = int.parse argv[top-at + 1]
    argv = argv[..top-at] + argv[top-at + 2..]
  argv = argv.map: absolute it
  c1 := {:}
  c2 := {:}
  for i := 0; i < argv.size; i += 2:
    add-counts c1 (steps-by-method argv[i] args)
    add-counts c2 (steps-by-method argv[i + 1] args)
  t1 := sum-values c1
  t2 := sum-values c2
  print "total: format 1 $t1, format 2 $t2 ($(signed t2 - t1))"
  names := names-of c1 c2
  get := : | counts name | counts.get name --if-absent=: 0
  sorted := names.sort: | a b |
    da := ((get.call c2 a) - (get.call c1 a)).abs
    db := ((get.call c2 b) - (get.call c1 b)).abs
    db != da ? db.compare-to da : a.compare-to b
  sorted[..min top sorted.size].do: | n/string |
    a := get.call c1 n
    b := get.call c2 n
    short := n.size > 60 ? n[..60] : n
    print "  $(pad-right short 60) $(pad-left "$a" 10) $(pad-left "$b" 10) $(pad-left (signed b - a) 10)"
  groups := {:}
  names.do: | n |
    g := category n
    groups["$g,1"] = (groups.get "$g,1" --if-absent=: 0) + (get.call c1 n)
    groups["$g,2"] = (groups.get "$g,2" --if-absent=: 0) + (get.call c2 n)
  print "by intrinsic (format 1, format 2, difference, share of the total difference):"
  ["HASH_FIND", "HASH_DO", "ARRAY_DO", "SMI_REPEAT", "other"].do: | g |
    g1 := groups.get "$g,1" --if-absent=: 0
    g2 := groups.get "$g,2" --if-absent=: 0
    d := g2 - g1
    share := 100.0 * d / (max 1 (t2 - t1))
    print "  $(pad-right g 12) $(pad-left "$g1" 10) $(pad-left "$g2" 10) $(pad-left (signed d) 10) $(pad-left (share.to-string --precision=1) 6)%"

add-counts total/Map counts/Map -> none:
  counts.do: | name n | total[name] = (total.get name --if-absent=: 0) + n

sum-values counts/Map -> int:
  return counts.values.reduce --initial=0: | a b | a + b

names-of c1/Map c2/Map -> List:
  names := {}
  names.add-all c1.keys
  names.add-all c2.keys
  return names.to-list

/** The executed instructions of the program in $dump, per method name. */
steps-by-method dump/string args/List -> Map:
  ms := methods dump
  entries := ms.map: it[0]
  process := pipe.fork SPEC-RUNNER
      [SPEC-RUNNER, "--trace-bci", "--max-steps", "400000000", dump, "--"] + args
      --create-stdout
      --create-stderr
  // Stdout is discarded.
  task:: catch: drain process.stdout
  by-bci := {:}
  reader := process.stderr.in
  while line := reader.read-line:
    if not line.starts-with "B ": continue
    space := line.index-of " " 2
    bci := int.parse line[2..(space < 0 ? line.size : space)]
    by-bci[bci] = (by-bci.get bci --if-absent=: 0) + 1
  process.wait
  counts := {:}
  by-bci.do: | bci n |
    i := (bisect-right entries bci) - 1
    name := (i >= 0 and bci < ms[i][1]) ? ms[i][2] : "?"
    counts[name] = (counts.get name --if-absent=: 0) + n
  return counts

drain stream/pipe.Stream -> none:
  reader := stream.in
  while reader.read: null

/** The number of elements of the sorted $list that are <= $x. */
bisect-right list/List x/int -> int:
  lo := 0
  hi := list.size
  while lo < hi:
    mid := (lo + hi) / 2
    if x < list[mid]: hi = mid
    else: lo = mid + 1
  return lo

category name/string -> string:
  if name.ends-with ".find-body_": return "HASH_FIND"
  if name.ends-with ".hash-do_" or name.ends-with ".skip_" or name == "Tombstone_.skip": return "HASH_DO"
  if name == "Map.do" or name == "Map.reverse-do" or name == "Set.do" or name == "Set.reverse-do": return "HASH_DO"
  if name.ends-with "Array_.do_": return "ARRAY_DO"
  if name == "SmallInteger_.repeat": return "SMI_REPEAT"
  return "other"
