// Provenance: Written for this project.

abstract class Shape:
  abstract area -> int
  scale -> int: return 2

class Square extends Shape:
  side/int
  constructor .side:
  area -> int: return side * side * scale

class Rect extends Shape:
  w/int
  h/int
  constructor .w .h:
  area -> int: return w * h * scale

class Tri extends Shape:
  b/int
  h/int
  constructor .b .h:
  area -> int: return b * h / 2
  scale -> int: return 1

class Hex extends Shape:
  s/int
  constructor .s:
  area -> int: return 3 * s * s

main:
  shapes := List 1000: | i |
    k := i % 4
    k == 0 ? (Square i) : k == 1 ? (Rect i 3) : k == 2 ? (Tri i 4) : (Hex i)
  total := 0
  20000.repeat:
    shapes.do: | shape/Shape | total += shape.area
  print total
