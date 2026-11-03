// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Test: assignments to globals and static fields must be renamed.
my-global := 1
/*
@ a-def
^
  [a-def, a-write, a-plus, a-read]
*/
typed-global/int := 1
/*
@ b-def
^
  [b-def, b-write, b-read]
*/

class WithStatic:
  // Static fields are globals in the compiler's IR.
  static my-static := 0
/*
         @ c-def
         ^
  [c-def, c-bare-write, c-bare-inc, c-write, c-plus, c-read]
*/

  foo:
    my-static = 1
/*
    @ c-bare-write
    ^
  [c-def, c-bare-write, c-bare-inc, c-write, c-plus, c-read]
*/
    my-static++
/*
    @ c-bare-inc
    ^
  [c-def, c-bare-write, c-bare-inc, c-write, c-plus, c-read]
*/

main:
  my-global = 2
/*
  @ a-write
  ^
  [a-def, a-write, a-plus, a-read]
*/
  my-global += 2
/*
  @ a-plus
  ^
  [a-def, a-write, a-plus, a-read]
*/
  print my-global
/*
        @ a-read
        ^
  [a-def, a-write, a-plus, a-read]
*/
  typed-global = 2
/*
  @ b-write
  ^
  [b-def, b-write, b-read]
*/
  print typed-global
/*
        @ b-read
        ^
  [b-def, b-write, b-read]
*/
  WithStatic.my-static = 1
/*
             @ c-write
             ^
  [c-def, c-bare-write, c-bare-inc, c-write, c-plus, c-read]
*/
  WithStatic.my-static += 2
/*
             @ c-plus
             ^
  [c-def, c-bare-write, c-bare-inc, c-write, c-plus, c-read]
*/
  print WithStatic.my-static
/*
                   @ c-read
                   ^
  [c-def, c-bare-write, c-bare-inc, c-write, c-plus, c-read]
*/
