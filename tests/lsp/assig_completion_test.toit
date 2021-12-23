// Copyright (C) 2020 Toitware ApS. All rights reserved.

import .assig_completion_test as prefix

global := 499

class SomeClass:
  field := null

  member -> any: return null
  member= val:

  only_setter= val:

  static static_field := 499

  static static_getter_setter: return null
  static static_getter_setter= val:

main:
  o := SomeClass

  // In theory, it would be nice not to complete members
  //   that can't get assigned, but in practice, code is
  //   written without the assignment (from left to right),
  //   so it's not crucial to have that filtering.
  o.field = 4
/*  ^~~~~
  + field, member, only_setter
  - o
*/

  // In theory we would like not to suggest `only_setter` as
  //   the compound assignment would fail. However, it's
  //   easier to suggest too much and rely on the error messages
  //   for the users.
  (SomeClass).member += 42
/*            ^~~~~~
  + field, member, only_setter
  - o
*/

  (prefix.SomeClass).member -= 1
/*                   ^~~~~~
  + field, member, only_setter
  - o
*/

  local := 499

  local = 2
/*^~~~~
  + local, global, SomeClass
  - member, field, static_field
*/

  local += 3
/*^~~~~
  + local, global, SomeClass
  - member, field, static_field
*/

  local++  // Should be the same as `local += 1`.
/*^~~~~
  + local, global, SomeClass
  - member, field, static_field
*/

  local = 2
/*     ^
  + local
  - member, field, static_field
*/

  local += 3
/*^
  + local, global, SomeClass
  - member, field, static_field
*/

  local += 3
/*     ^
  + local
  - member, field, static_field, global, SomeClass
*/

  global = 2
/*      ^
  + global
  - member, field, static_field
*/

  global += 3
/*      ^
  + global
  - member, field, static_field
*/

  // Since `SomeClass` has a default-constructor, we need to list the
  //   instance members as well.
  SomeClass.static_field = 2
/*          ^~~~~~~~~~~~
  + static_field, static_getter_setter
  - global, member, field
*/

  SomeClass.static_field += 2
/*                      ^
  + static_field
  - global
*/

  SomeClass.static_field += 2
/*                      ^
  + static_field
  - global
*/

  SomeClass.static_getter_setter += 2
/*                              ^
  + static_getter_setter
  - global
*/

  prefix.SomeClass.static_field = 2
/*                 ^~~~~~~~~~~~
  + static_field, static_getter_setter
  - global, field, member
*/

  prefix.SomeClass.static_field += 2
/*                             ^
  + static_field
  - global
*/
