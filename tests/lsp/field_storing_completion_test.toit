// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

class A:
  field_A := null

  member -> any: return null
  member= val:

class B:
  field_B1 := null
  field_B2 ::= null
  field_B3 := ?
  field_B4 ::= ?
  field_B5 /int := 0
  field_B6 /int ::= 0

  constructor .field_B1:
/*             ^~~~~~~~
  + field_B1, field_B2, field_B3, field_B4, field_B5, field_B6
  - *
*/
    field_B2 = 0
    field_B3 = 0
    field_B4 = 0
    field_B5 = 0
    field_B6 = 0

  constructor.named .field_B1:
/*                           ^
  + field_B1
  - field_A, setter, member
*/
    field_B2 = 0
    field_B3 = 0
    field_B4 = 0
    field_B5 = 0
    field_B6 = 0

  constructor.factory .field_B1:
/*                     ^~~~~~~~
  - *
*/
    return B 0

  setter= val:

  member .field_B1:
/*        ^~~~~~~~
  + field_B1, field_B2, field_B3, field_B4, field_B5, field_B6
  - *
*/

  static foo .field_B1:
/*            ^~~~~~~~
  - *
*/

foo .field_storing:
/*   ^~~~~~~~~~~~~
  - *
*/

main:
