// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .assig-completion-test as prefix

global := 499

class SomeClass:
  field := null

  member -> any: return null
  member= val:

  only-setter= val:

  static static-field := 499

  static static-getter-setter: return null
  static static-getter-setter= val:

main:
  o := SomeClass

  // In theory, it would be nice not to complete members
  //   that can't get assigned, but in practice, code is
  //   written without the assignment (from left to right),
  //   so it's not crucial to have that filtering.
  o.field = 4
/*  ^~~~~
  + field, member, only-setter
  - o
*/

  // In theory we would like not to suggest `only-setter` as
  //   the compound assignment would fail. However, it's
  //   easier to suggest too much and rely on the error messages
  //   for the users.
  (SomeClass).member += 42
/*            ^~~~~~
  + field, member, only-setter
  - o
*/

  (prefix.SomeClass).member -= 1
/*                   ^~~~~~
  + field, member, only-setter
  - o
*/

  local := 499

  local = 2
/*^~~~~
  + local, global, SomeClass
  - member, field, static-field
*/

  local += 3
/*^~~~~
  + local, global, SomeClass
  - member, field, static-field
*/

  local++  // Should be the same as `local += 1`.
/*^~~~~
  + local, global, SomeClass
  - member, field, static-field
*/

  local = 2
/*     ^
  + local
  - member, field, static-field
*/

  local += 3
/*^
  + local, global, SomeClass
  - member, field, static-field
*/

  local += 3
/*     ^
  + local
  - member, field, static-field, global, SomeClass
*/

  global = 2
/*      ^
  + global
  - member, field, static-field
*/

  global += 3
/*      ^
  + global
  - member, field, static-field
*/

  // Since `SomeClass` has a default-constructor, we need to list the
  //   instance members as well.
  SomeClass.static-field = 2
/*          ^~~~~~~~~~~~
  + static-field, static-getter-setter
  - global, member, field
*/

  SomeClass.static-field += 2
/*                      ^
  + static-field
  - global
*/

  SomeClass.static-field += 2
/*                      ^
  + static-field
  - global
*/

  SomeClass.static-getter-setter += 2
/*                              ^
  + static-getter-setter
  - global
*/

  prefix.SomeClass.static-field = 2
/*                 ^~~~~~~~~~~~
  + static-field, static-getter-setter
  - global, field, member
*/

  prefix.SomeClass.static-field += 2
/*                             ^
  + static-field
  - global
*/
