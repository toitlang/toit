// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .definition_imported
import .definition_imported as prefix

fun:
/*
@ fun
*/

class SomeClass:
/*    @ SomeClass */

  member foo:
/*@ member */

  member --named:
/*       @ named */

class SomeClass2:
  constructor:
/*@ unnamed-constructor */

  constructor.named:
/*@ named-constructor */

main:
  fun
/*^
  [fun]
*/

  some := SomeClass
/*          ^
  [SomeClass]
*/
  some.member 499
/*       ^
  [member]
*/
  some.member --named=499
/*                ^
  [named]
*/
  some2 := SomeClass2
/*           ^
  [unnamed-constructor]
*/
  some2b := SomeClass2.named
/*                       ^
  [named-constructor]
*/

  imported := ImportedClass
/*              ^
  [ImportedClass]
*/

  imported = prefix.ImportedClass
/*                    ^
  [ImportedClass]
*/

  // Make sure it also works inside asserts.
  assert: imported = ImportedClass
/*                     ^
  [ImportedClass]
*/
