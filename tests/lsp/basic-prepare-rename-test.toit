// Copyright (C) 2026 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import core as my_core

foo x:
/*
^
  foo
*/
/*
    ^
  x
*/
/*
      ^
  null
*/
  local := x + 1
/*
  ^
  local
*/
/*
           ^
  x
*/
  return local
/*
  ^
  null
*/
/*
         ^
  local
*/

bar y:
  return y * 2

class SomeClass:
/*
      ^
  SomeClass
*/
  field := 0
/*
  ^
  field
*/

  member:
/*
  ^
  member
*/
    return field
/*
           ^
  field
*/

main:
  foo-instance := SomeClass
/*
  ^
  foo-instance
*/
/*
                  ^
  SomeClass
*/
  foo-instance.member
/*
  ^
  foo-instance
*/
/*
               ^
  member
*/

  SomeClass
/*
  ^
  SomeClass
*/

  str := "string literal"
/*
           ^
  null
*/

  b := 42
/*
       ^
  null
*/
