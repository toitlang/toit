// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Test: the left-hand side of an assignment to a local must be renamed.
plain:
  xx := 1
/*
  @ a-def
  ^
  [a-def, a-write, a-read]
*/
  xx = 2
/*
  @ a-write
  ^
  [a-def, a-write, a-read]
*/
  print xx
/*
        @ a-read
        ^
  [a-def, a-write, a-read]
*/

typed:
  xx/int := 1
/*
  @ b-def
  ^
  [b-def, b-write, b-read]
*/
  xx = 2
/*
  @ b-write
  ^
  [b-def, b-write, b-read]
*/
  print xx
/*
        @ b-read
        ^
  [b-def, b-write, b-read]
*/

parameter xx:
/*
          @ c-def
          ^
  [c-def, c-write, c-read]
*/
  xx = 2
/*
  @ c-write
  ^
  [c-def, c-write, c-read]
*/
  print xx
/*
        @ c-read
        ^
  [c-def, c-write, c-read]
*/

in-block:
  xx := 1
/*
  @ e-def
  ^
  [e-def, e-write, e-read]
*/
  2.repeat:
    xx = 3
/*
    @ e-write
    ^
  [e-def, e-write, e-read]
*/
  print xx
/*
        @ e-read
        ^
  [e-def, e-write, e-read]
*/

block-parameter:
  2.repeat: |xx|
/*
             @ f-def
             ^
  [f-def, f-write, f-read]
*/
    xx = 3
/*
    @ f-write
    ^
  [f-def, f-write, f-read]
*/
    print xx
/*
          @ f-read
          ^
  [f-def, f-write, f-read]
*/

lambda-parameter:
  l := :: |xx|
/*
           @ g-def
           ^
  [g-def, g-write, g-read]
*/
    xx = 3
/*
    @ g-write
    ^
  [g-def, g-write, g-read]
*/
    print xx
/*
          @ g-read
          ^
  [g-def, g-write, g-read]
*/
  l.call 1

loop-variable:
  for xx := 0; xx < 3; xx = xx + 1:
/*
      @ h-def
      ^
  [h-def, h-cond, h-inc, h-read, h-body]
*/
/*
               @ h-cond
               ^
  [h-def, h-cond, h-inc, h-read, h-body]
*/
/*
                       @ h-inc
                       ^
  [h-def, h-cond, h-inc, h-read, h-body]
*/
/*
                            @ h-read
                            ^
  [h-def, h-cond, h-inc, h-read, h-body]
*/
    print xx
/*
          @ h-body
          ^
  [h-def, h-cond, h-inc, h-read, h-body]
*/

compound:
  xx := 1
/*
  @ i-def
  ^
  [i-def, i-plus, i-inc, i-read]
*/
  xx += 2
/*
  @ i-plus
  ^
  [i-def, i-plus, i-inc, i-read]
*/
  xx++
/*
  @ i-inc
  ^
  [i-def, i-plus, i-inc, i-read]
*/
  print xx
/*
        @ i-read
        ^
  [i-def, i-plus, i-inc, i-read]
*/

in-finally:
  try:
    xx := 1
/*
    @ j-def
    ^
  [j-def, j-write, j-read]
*/
    xx = 2
/*
    @ j-write
    ^
  [j-def, j-write, j-read]
*/
    print xx
/*
          @ j-read
          ^
  [j-def, j-write, j-read]
*/
  finally:
    yy := 1
/*
    @ k-def
    ^
  [k-def, k-write]
*/
    yy = 2
/*
    @ k-write
    ^
  [k-def, k-write]
*/

main:
  plain
  typed
  parameter 1
  in-block
  block-parameter
  lambda-parameter
  loop-variable
  compound
  in-finally
