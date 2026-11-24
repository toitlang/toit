// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Run with 'toit run --untrusted'. An untrusted program can make a map weak
// (Map.weak: add_finalizer on a Map, allowed for untrusted programs), and an
// old-space collection then replaces the map's otherwise unreachable values
// by null (WeakMapFinalizerNode::weak_processing, src/heap_roots.cc): the
// collector writes into a reachable object. This characterizes the
// behaviour the GC model does not state yet (verified/cxx/annotated/README.md,
// "Findings"); the strongly held value stays.

class Payload:
  value/int
  constructor .value:

main:
  map := Map.weak
  map["key"] = Payload 42
  strong := Payload 7
  map["kept"] = strong
  rounds := 0
  keep := []
  while map["key"] != null and rounds < 100000:
    keep.add (ByteArray 1000)
    if keep.size > 300: keep = []
    rounds++
  print "key=$(map["key"] == null ? "null" : "present") kept=$(map["kept"] == null ? "null" : "present") $strong.value"
