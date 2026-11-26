// Copyright (C) 2026 Toit contributors.

// A larger untrusted program for the install-time measurements: JSON,
// base64, hex, CRC, a sorted map, string formatting and a few classes.

import encoding.json
import encoding.hex
import crypto.crc
import expect show *

class Point:
  x/int
  y/int
  constructor .x .y:
  operator + other/Point -> Point: return Point (x + other.x) (y + other.y)
  stringify -> string: return "($x, $y)"

abstract class Shape:
  abstract area -> float
  describe -> string: return "$(name): $(%.2f area)"
  abstract name -> string

class Circle extends Shape:
  r/float
  constructor .r:
  area -> float: return 3.14159 * r * r
  name -> string: return "circle"

class Rect extends Shape:
  w/float
  h/float
  constructor .w .h:
  area -> float: return w * h
  name -> string: return "rect"

main:
  data := {
    "name": "big",
    "values": List 20: it * it,
    "nested": { "a": [1, 2, 3], "b": { "c": "d" } },
  }
  encoded := json.encode data
  decoded := json.decode encoded
  expect-equals "big" decoded["name"]
  expect-equals 361 decoded["values"][19]
  text := json.stringify decoded
  h := hex.encode encoded
  expect-equals encoded (hex.decode h)
  c := crc.crc32 encoded
  print "crc $c"
  shapes := [Circle 1.5, Rect 2.0 3.0, Circle 0.5]
  shapes.sort --in-place: | a b | a.area.compare-to b.area
  shapes.do: print it.describe
  sum := Point 0 0
  10.repeat: sum += Point it (it * 2)
  print "sum $sum"
  words := "the quick brown fox jumps over the lazy dog".split " "
  counts := {:}
  words.do: counts.update it --init=0: it + 1
  print "counts $counts"
  print "joined $(words.join "-") $(%08.3f 3.14159) $(%x 255)"
