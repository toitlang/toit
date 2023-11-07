// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .definition-imported
import .definition-imported as prefix

import .definition-imported as ambiguous
import .definition-imported2 as ambiguous

fun:
fun x:

class SomeClass:
  static static-fun:

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
  + ImportedClass, ImportedClass2, ImportedInterface, ImportedMixin
  - *
*/

bar2 y / ImportedClass -> none:
/*       ^~~~~~~~~~~~~~~~~~~~~~
  + ImportedClass, ImportedClass2, any, SomeClass, prefix
  - none, foo, null
*/

bar3 y / ImportedClass -> prefix.ImportedInterface:
/*                               ^~~~~~~~~~~~~~~~~~
  + ImportedClass, ImportedClass2, ImportedInterface, ImportedMixin
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
  + ImportedInterface, ImportedClass, ImportedClass2, ImportedMixin
  - *
*/

  static static-field / SomeClass := SomeClass
/*                      ^~~~~~~~~~~~~~~~~~~~~~
  + ImportedClass, ImportedClass2, SomeClass, any, prefix
  - none, foo, null
*/

  static static-method x / SomeClass: return null
/*                         ^~~~~~~~~~~~~~~~~~~~~~
  + ImportedClass, ImportedClass2, SomeClass, any, prefix
  - none, foo, null
*/

  static static-method -> ImportedInterface: throw "foo"
/*                        ^~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  + ImportedClass, ImportedClass2, SomeClass, any, prefix
  - foo, null
*/

  static static-method2 -> prefix.ImportedInterface: throw "foo"
/*                                ^~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  + ImportedInterface, ImportedClass, ImportedClass2, ImportedMixin
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
  + ImportedClass, ImportedClass2, ImportedInterface, ImportedMixin
  - *
*/
  unreachable

bad3 -> SomeClass.static-fun:
/*                ^~~~~~~~~~~
  - *
*/
  unreachable
