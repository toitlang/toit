// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .assig-definition-test as prefix

global := 499
/*
@ global
*/

class SomeClass:
  field := null
/*@ field */

  member -> any: return null
/*@ member */
  member= val:
/*@ member_setter */

  only-setter= val:
/*@ only_setter */

  static static-field := 499
/*       @ static_field */

  static static-getter-setter: return null
/*       @ static_getter */
  static static-getter-setter= val:
/*       @ static_setter */

main:
  o := SomeClass

  // In theory, it would be nice not to complete members
  //   that can't get assigned, but in practice, code is
  //   written without the assignment (from left to right),
  //   so it's not crucial to have that filtering.
  o.field = 4
/*    ^
  [field]
*/

  // In theory we would like not to suggest `only_setter` as
  //   the compound assignment would fail. However, it's
  //   easier to suggest too much and rely on the error messages
  //   for the users.
  SomeClass.member += 42
/*            ^
  [member, member_setter]
*/

  prefix.SomeClass.member -= 1
/*                   ^
  [member, member_setter]
*/

  prefix.SomeClass.member = 1
/*                   ^
  [member_setter]
*/

  o.only-setter = 1
/*         ^
  [only_setter]
*/

  local := 499
/*@ local */

  local = 2
/*  ^
  [local]
*/

  local += 3
/* ^
  [local]
*/

  local++  // Should be the same as `local += 1`.
/* ^
  [local]
*/

  global = 2
/*    ^
  [global]
*/

  global += 3
/*   ^
  [global]
*/

  SomeClass.static-field = 2
/*             ^
  [static_field]
*/

  SomeClass.static-field += 2
/*                   ^
  [static_field]
*/

  SomeClass.static-getter-setter = 2
/*                         ^
  [static_setter]
*/

  SomeClass.static-getter-setter
/*                         ^
  [static_getter]
*/

  SomeClass.static-getter-setter += 2
/*                         ^
  [static_getter, static_setter]
*/

  prefix.SomeClass.static-field = 2
/*                    ^
  [static_field]
*/
