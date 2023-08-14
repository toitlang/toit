// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

class A:
  field-A := null

  member -> any: return null
  member= val:

class B:
  field-B1 := null
  field-B2 ::= null
  field-B3 := ?
  field-B4 ::= ?
  field-B5 /int := 0
  field-B6 /int ::= 0

  constructor .field-B1:
/*             ^~~~~~~~
  + field-B1, field-B2, field-B3, field-B4, field-B5, field-B6
  - *
*/
    field-B2 = 0
    field-B3 = 0
    field-B4 = 0
    field-B5 = 0
    field-B6 = 0

  constructor.named .field-B1:
/*                           ^
  + field-B1
  - field-A, setter, member
*/
    field-B2 = 0
    field-B3 = 0
    field-B4 = 0
    field-B5 = 0
    field-B6 = 0

  constructor.factory .field-B1:
/*                     ^~~~~~~~
  - *
*/
    return B 0

  setter= val:

  member .field-B1:
/*        ^~~~~~~~
  + field-B1, field-B2, field-B3, field-B4, field-B5, field-B6
  - *
*/

  static foo .field-B1:
/*            ^~~~~~~~
  - *
*/

foo .field-storing:
/*   ^~~~~~~~~~~~~
  - *
*/

main:
