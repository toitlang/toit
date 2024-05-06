// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

foo x/int -> none:

bar y/float -> none:

int-fun -> int: return 0
float-fun -> float: return 1.0

main:
  foo 1 + 2.0
  foo 1.0 + 2
  bar 1 + 2
  foo int-fun + 2.0
  foo 2.0 + int-fun
  bar int-fun
  bar int-fun + 1
  bar 0 + int-fun
  foo int-fun + float-fun
  foo float-fun + int-fun
  bar int-fun + int-fun
  bar float-fun + int-fun
  foo int-fun + int-fun

  foo int-fun - float-fun
  foo float-fun - int-fun
  bar int-fun - int-fun
  bar float-fun - int-fun
  foo int-fun - int-fun

  foo int-fun * float-fun
  foo float-fun * int-fun
  bar int-fun * int-fun
  bar float-fun * int-fun
  foo int-fun * int-fun

  foo int-fun / float-fun
  foo float-fun / int-fun
  bar int-fun / int-fun
  bar float-fun / int-fun
  foo int-fun / int-fun

  foo int-fun % float-fun
  foo float-fun % int-fun
  bar int-fun % int-fun
  bar float-fun % int-fun
  foo int-fun % int-fun

  foo -float-fun
  bar -int-fun

  unresolved
