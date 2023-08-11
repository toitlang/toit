// Copyright (C) 2021 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .completion-imported
import .completion-imported as prefix
/*          ^~~~~~~~~~~~~~~~~~~~~~~~~
  + completion-imported
  - filtered-completion-test
*/

import core as core
/*       ^
  + core
  - monitor
*/

import .completion-imported show ImportedClass
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
  other-member:
  block-member [block]:

  static static-field := 499
  static static-xfield := 499

  static fun:
    static-xfield
/*           ^
  + static-xfield
  - static-field
*/


global := 499
global2 := 42

toplevel-fun x: return x

foo [block]:

main:
  global
/*  ^
  + global, global2
  - SomeClass, main, toplevel-fun, null, true, false, return, member
*/

  SomeClass.static-field
/*                   ^
  + static-field
  - static-xfield
*/

  some := SomeClass

  some.member
/*       ^
  + member
  - other-member
*/

  foo:
    some.block-member:
      continue.block-member
/*              ^~~~~~~~~~~
  + block-member
  - *
*/

  if-count := 499
  if-count++
/*  ^~~~~~~~
  + if-count
*/
