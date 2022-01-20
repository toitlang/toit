// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .completion_imported
import .completion_imported as prefix
/*          ^~~~~~~~~~~~~~~~~~~~~~~~~
  + completion_imported
  - filtered_completion_test
*/

import core as core
/*       ^
  + core
  - monitor
*/

import .completion_imported show ImportedClass
/*                                        ^
  + ImportedClass
  - ImportedInterface
*/

class SomeClass:
  field / int
  xfield := 42

  constructor:
    field = 499

  constructor .field:
/*              ^
  + field
  - xfield
*/

  member:
  other_member:
  block_member [block]:

  static static_field := 499
  static static_xfield := 499

  static fun:
    static_xfield
/*           ^
  + static_xfield
  - static_field
*/


global := 499
global2 := 42

toplevel_fun x: return x

foo [block]:

main:
  global
/*  ^
  + global, global2
  - SomeClass, main, toplevel_fun, null, true, false, return, member
*/

  SomeClass.static_field
/*                   ^
  + static_field
  - static_xfield
*/

  some := SomeClass

  some.member
/*       ^
  + member
  - other_member
*/

  foo:
    some.block_member:
      continue.block_member
/*              ^~~~~~~~~~~
  + block_member
  - *
*/

  if_count := 499
  if_count++
/*  ^~~~~~~~
  + if_count
*/
