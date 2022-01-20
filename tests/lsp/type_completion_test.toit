// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .definition_imported
import .definition_imported as prefix

import .definition_imported as ambiguous
import .definition_imported2 as ambiguous

fun:
fun x:

class SomeClass:
  static static_fun:

foo x / SomeClass:
/*      ^~~~~~~~~~
  + SomeClass, any, ImportedInterface, prefix
  - foo, none, null
*/

foo -> SomeClass:
/*     ^~~~~~~~~~
  + SomeClass, any, ImportedInterface, prefix, none
  - foo, null
*/
  unreachable

bar y / prefix.ImportedClass -> none:
/*             ^~~~~~~~~~~~~~~~~~~~~~
  + ImportedClass, ImportedClass2, ImportedInterface
  - *
*/

bar2 y / ImportedClass -> none:
/*       ^~~~~~~~~~~~~~~~~~~~~~
  + ImportedClass, ImportedClass2, any, SomeClass, prefix
  - none, foo, null
*/

bar3 y / ImportedClass -> prefix.ImportedInterface:
/*                               ^~~~~~~~~~~~~~~~~~
  + ImportedClass, ImportedClass2, ImportedInterface
  - *
*/
  unreachable

global / ImportedClass? := null
/*       ^~~~~~~~~~~~~~~~~~~~~~
  + ImportedClass, ImportedClass2, SomeClass, any, prefix
  - none, foo, null
*/

class A:
  constructor .field:

  field / SomeClass := ?
/*        ^~~~~~~~~~~~~~
  + ImportedClass, ImportedClass2, SomeClass, any, prefix
  - none, foo, null
*/

  method x / SomeClass: return null
/*           ^~~~~~~~~~~~~~~~~~~~~~
  + ImportedClass, ImportedClass2, SomeClass, any, prefix
  - none, foo, null
*/

  method -> prefix.ImportedInterface: throw "foo"
/*                 ^~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  + ImportedInterface, ImportedClass, ImportedClass2
  - *
*/

  static static_field / SomeClass := SomeClass
/*                      ^~~~~~~~~~~~~~~~~~~~~~
  + ImportedClass, ImportedClass2, SomeClass, any, prefix
  - none, foo, null
*/

  static static_method x / SomeClass: return null
/*                         ^~~~~~~~~~~~~~~~~~~~~~
  + ImportedClass, ImportedClass2, SomeClass, any, prefix
  - none, foo, null
*/

  static static_method -> ImportedInterface: throw "foo"
/*                        ^~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  + ImportedClass, ImportedClass2, SomeClass, any, prefix
  - foo, null
*/

  static static_method2 -> prefix.ImportedInterface: throw "foo"
/*                                ^~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  + ImportedInterface, ImportedClass, ImportedClass2
  - *
*/



bad -> prefix.ImportedClass2.named:
/*                           ^~~~~~
  - *
*/
  unreachable

// TODO(florian): we could consider not completing if they are
//   ambiguous.
bad2 -> ambiguous.ImportedClass:
/*                ^~~~~~~~~~~~~~
  + ImportedClass, ImportedClass2, ImportedInterface
  - *
*/
  unreachable

bad3 -> SomeClass.static_fun:
/*                ^~~~~~~~~~~
  - *
*/
  unreachable
