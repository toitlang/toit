// Copyright (C) 2026 Toit contributors.

class Point:
  x := 0
  y := 0
  constructor .x .y:
  operator + other/Point -> Point: return Point (x + other.x) (y + other.y)

main:
  print "UNTRUSTED hello"
  p := Point 1 2
  100.repeat: p += Point it 1
  print "UNTRUSTED point $p.x $p.y"
