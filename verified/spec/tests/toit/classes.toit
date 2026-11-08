// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

interface Shape:
  area -> float
  name -> string

abstract class Base implements Shape:
  static count := 0
  constructor:
    count++
  abstract area -> float
  name -> string: return "base"
  describe: return "$name with area $(%.2f area)"

class Circle extends Base:
  r/float
  constructor .r:
    super
  area -> float: return 3.0 * r * r
  name: return "circle"

class Rect extends Base:
  w/float
  h/float
  constructor .w .h:
    super
  area -> float: return w * h

class Point:
  x := 0
  y := 0
  constructor:
  constructor .x .y:
  operator + other/Point: return Point x + other.x y + other.y
  operator == other: return other is Point and other.x == x and other.y == y
  hash-code: return x * 31 + y
  stringify: return "($x, $y)"

lazy-global ::= compute-lazy
compute-lazy:
  print "computing lazy global"
  return 1234

mixin Greeter:
  greet: return "hello from $(this)"

class Greeted extends Object with Greeter:
  stringify: return "Greeted"

main:
  shapes := [Circle 1.0, Rect 2.0 3.0, Circle 0.5]
  shapes.do: print it.describe
  print Base.count
  print (shapes.map: it is Circle)
  print (shapes[1] is Shape)
  print ((shapes[0] as Shape).name)
  p := Point 1 2
  q := Point 3 4
  print p + q
  print (p == (Point 1 2))
  print ({p: "p"}[Point 1 2])
  print Point
  pt := Point
  pt.x = 10
  pt.y += 5
  print pt
  print lazy-global
  print lazy-global
  print (Greeted).greet
  print (identical p p)
  print (identical p (Point 1 2))
  print (3 is int)
  print ("s" is string)
  print (null is any)
  x/any := 3
  print (x is float)
