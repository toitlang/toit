// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Test: captured variables must only be renamed at their real occurrences.
//   The compiler adds a synthetic reference with the range of the lambda for
//   each captured variable. That reference must not produce an edit.
multi-line:
  xx := 1
/*
  @ a-def
  ^
  [a-def, a-use]
*/
  l := ::
    print 1
    print xx
/*
          @ a-use
          ^
  [a-def, a-use]
*/
    print 12345
  l.call

one-line-not-last:
  xx := 1
/*
  @ b-def
  ^
  [b-def, b-use]
*/
  l := :: print xx + 12345
/*
                @ b-use
                ^
  [b-def, b-use]
*/
  l.call

// The lambda's range ends with another captured variable.
two-captures:
  xx := 1
/*
  @ c-def
  ^
  [c-def, c-use]
*/
  yy := 2
/*
  @ d-def
  ^
  [d-def, d-use]
*/
  l := :: print xx + yy
/*
                @ c-use
                ^
  [c-def, c-use]
*/
/*
                     @ d-use
                     ^
  [d-def, d-use]
*/
  l.call

// The lambda's range ends with a dotted name that matches the captured variable.
class Holder:
  xx := 0
/*
  @ f-def
  ^
  [f-def, f-member]
*/

ends-with-member:
  xx := 1
/*
  @ e-def
  ^
  [e-def, e-use]
*/
  holder := Holder
  l := :: print xx + holder.xx
/*
                @ e-use
                ^
  [e-def, e-use]
*/
/*
                            @ f-member
                            ^
  [f-def, f-member]
*/
  l.call

nested:
  xx := 1
/*
  @ g-def
  ^
  [g-def, g-use]
*/
  outer := ::
    inner := ::
      print 1
      print xx
/*
            @ g-use
            ^
  [g-def, g-use]
*/
    inner.call
  outer.call

mutated:
  xx := 1
/*
  @ h-def
  ^
  [h-def, h-write, h-read]
*/
  l := ::
    xx = 2
/*
    @ h-write
    ^
  [h-def, h-write, h-read]
*/
    print xx
/*
          @ h-read
          ^
  [h-def, h-write, h-read]
*/
    print 1
  l.call

block-in-lambda:
  xx := 1
/*
  @ i-def
  ^
  [i-def, i-use]
*/
  l := ::
    2.repeat:
      print xx
/*
            @ i-use
            ^
  [i-def, i-use]
*/
    print 1
  l.call

captured-param param:
/*
               @ j-def
               ^
  [j-def, j-use]
*/
  return ::
    print param
/*
          @ j-use
          ^
  [j-def, j-use]
*/
    print 1

captured-named-param --param:
/*
                       @ k-def
                       ^
  [k-def, k-use, k-call]
*/
  return ::
    print param
/*
          @ k-use
          ^
  [k-def, k-use, k-call]
*/
    print 1

captured-block-param:
  2.repeat: |xx|
/*
             @ l-def
             ^
  [l-def, l-use]
*/
    l := ::
      print xx
/*
            @ l-use
            ^
  [l-def, l-use]
*/
      print 1
    l.call

captured-lambda-param:
  outer := :: |xx|
/*
               @ m-def
               ^
  [m-def, m-use]
*/
    inner := ::
      print xx
/*
            @ m-use
            ^
  [m-def, m-use]
*/
      print 1
    inner.call
  outer.call 1

captured-loop-variable:
  for xx := 0; xx < 3; xx++:
/*
      @ n-def
      ^
  [n-def, n-cond, n-inc, n-use]
*/
/*
               @ n-cond
               ^
  [n-def, n-cond, n-inc, n-use]
*/
/*
                       @ n-inc
                       ^
  [n-def, n-cond, n-inc, n-use]
*/
    l := ::
      print xx
/*
            @ n-use
            ^
  [n-def, n-cond, n-inc, n-use]
*/
      print 1
    l.call

task-argument:
  xx := 1
/*
  @ o-def
  ^
  [o-def, o-use]
*/
  task::
    print xx
/*
          @ o-use
          ^
  [o-def, o-use]
*/
    print 1

main:
  multi-line
  one-line-not-last
  two-captures
  ends-with-member
  nested
  mutated
  block-in-lambda
  captured-param 1
  captured-named-param --param=1
/*
                         @ k-call
                         ^
  [k-def, k-use, k-call]
*/
  captured-block-param
  captured-lambda-param
  captured-loop-variable
  task-argument
