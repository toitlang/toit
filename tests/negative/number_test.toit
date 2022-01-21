// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

foo x/int -> none:

bar y/float -> none:

int_fun -> int: return 0
float_fun -> float: return 1.0

main:
  foo 1 + 2.0
  foo 1.0 + 2
  bar 1 + 2
  foo int_fun + 2.0
  foo 2.0 + int_fun
  bar int_fun
  bar int_fun + 1
  bar 0 + int_fun
  foo int_fun + float_fun
  foo float_fun + int_fun
  bar int_fun + int_fun
  bar float_fun + int_fun
  foo int_fun + int_fun

  foo int_fun - float_fun
  foo float_fun - int_fun
  bar int_fun - int_fun
  bar float_fun - int_fun
  foo int_fun - int_fun

  foo int_fun * float_fun
  foo float_fun * int_fun
  bar int_fun * int_fun
  bar float_fun * int_fun
  foo int_fun * int_fun

  foo int_fun / float_fun
  foo float_fun / int_fun
  bar int_fun / int_fun
  bar float_fun / int_fun
  foo int_fun / int_fun

  foo int_fun % float_fun
  foo float_fun % int_fun
  bar int_fun % int_fun
  bar float_fun % int_fun
  foo int_fun % int_fun

  foo -float_fun
  bar -int_fun

  unresolved
