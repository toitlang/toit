// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

twice [block]:
  block.call
  block.call

apply x [block] -> int:
  return block.call x

compose x [f] [g]:
  return f.call (g.call x)

count-up n [block]:
  for i := 0; i < n; i++:
    block.call i

nested-outer:
  total := 0
  count-up 3: | i |
    count-up 3: | j |
      total += i * 10 + j
  return total

main:
  counter := 0
  twice: counter++
  print counter
  print (apply 20: it + 1)
  print (compose 5 (: it * 2) (: it + 3))
  print nested-outer

  // Blocks capturing and mutating outer locals at several depths.
  a := 1
  b := 2
  twice:
    twice:
      a += b
      b += 1
  print "$a $b"

  // Block aliases.
  blk := (: | x | x * x)
  print (apply 7 blk)

  // Lambdas capture by value and can be stored.
  lambdas := []
  3.repeat: | i |
    lambdas.add:: i * 100
  print (lambdas.map: it.call)
  adder := :: | x y | x + y
  print (adder.call 3 4)
  greeting := "hi"
  hello := :: "$greeting there"
  print hello.call

  // Lambdas with many captured variables.
  p := 1
  q := 2
  r := 3
  many := :: | z | p + q + r + z
  print (many.call 10)

  // Block with explicit continue.
  result := []
  10.repeat:
    if it % 3 == 0: continue.repeat
    result.add it
  print result
