// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .definition_imported
import .definition_imported as prefix

import .definition_imported as ambiguous
import .definition_imported2 as ambiguous

fun:
/*
@ fun
*/

fun x:
/*
@ fun2
*/

class SomeClass:
/*    @ SomeClass */

  static static_fun:
/*       @ static_fun */


foo x / SomeClass:
/*       ^
  [SomeClass]
*/

foo -> SomeClass:
/*       ^
  [SomeClass]
*/
  unreachable

bar y / prefix.ImportedClass -> none:
/*               ^
  [ImportedClass]
*/

bar2 y / ImportedClass -> none:
/*               ^
  [ImportedClass]
*/

bar3 y / ImportedClass -> prefix.ImportedInterface:
/*                                   ^
  [ImportedInterface]
*/
  unreachable

global / ImportedClass? := null
/*                  ^
  [ImportedClass]
*/

class A:
  constructor .field:

  field / SomeClass := ?
/*              ^
  [SomeClass]
*/

  method x / SomeClass: return null
/*              ^
  [SomeClass]
*/

  method -> prefix.ImportedInterface: throw "foo"
/*                   ^
  [ImportedInterface]
*/

  static static_field / SomeClass := SomeClass
/*                       ^
  [SomeClass]
*/

  static static_method x / SomeClass: return null
/*                           ^
  [SomeClass]
*/

  static static_method -> prefix.ImportedInterface: throw "foo"
/*                                  ^
  [ImportedInterface]
*/



bad -> fun:
/*      ^
  [fun, fun2]
*/
  unreachable

bad x / fun:
/*      ^
  [fun, fun2]
*/

// TODO(florian): we could improve the following resolution to
//   point to the constructor.
bad2 -> prefix.ImportedClass.named:
/*                            ^
  []
*/
  unreachable

bad3 -> ambiguous.ImportedClass:
/*                 ^
  [ImportedClass, ImportedClass_ambig]
*/
  unreachable

bad4 -> SomeClass.static_fun:
/*                 ^
  []
*/
  unreachable

bad5 -> SomeClass.static_fun:
/*         ^
  [SomeClass]
*/
  unreachable

bad6 -> SomeClass.non_existent:
/*         ^
  [SomeClass]
*/
  unreachable
