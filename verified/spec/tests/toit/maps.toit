// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

class Key:
  id/int
  constructor .id:
  hash-code: return id % 3
  operator == other: return other is Key and other.id == id
  stringify: return "K$id"

main:
  m := {:}
  m["one"] = 1
  m["two"] = 2
  m["three"] = 3
  print m
  print m.size
  print m["two"]
  print (m.get "four")
  print (m.get "four" --if-absent=: "absent")
  print (m.contains "one")
  m.remove "two"
  print m
  print m.keys
  print m.values
  m.do: | k v | print "$k=$v"
  m.do --reversed: | k v | print "rev $k=$v"
  // Integer keys and many entries (index rebuilds).
  squares := {:}
  200.repeat: squares[it] = it * it
  print squares.size
  print squares[199]
  sum := 0
  squares.do --values: sum += it
  print sum
  150.repeat: squares.remove it
  print squares.size
  print squares.keys.first
  // Custom keys with collisions.
  km := {:}
  10.repeat: km[Key it] = "v$it"
  print km[Key 7]
  print km.size
  km.remove (Key 4)
  print km.keys
  // Update and get-or-insert.
  counts := {:}
  "the quick brown fox jumps over the lazy dog the end".split " ": | word |
    counts.update word --init=0: it + 1
  print counts
  print (counts.get "the")
  // Map with list values, nested maps.
  nested := {"a": {"b": [1, 2]}, "c": {:}}
  print nested
  print nested["a"]["b"][1]
  // Map.map and filter.
  print (m.map: | k v | v * 10)
  print (squares.filter: | k v | k % 10 == 0)
  // Sets of strings.
  words := {"x", "y", "x", "z"}
  print words
  print words.size
