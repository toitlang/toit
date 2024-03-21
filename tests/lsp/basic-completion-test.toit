// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .completion-imported
import .completion-imported as prefix

class SomeClass:
  member:

global := 499

toplevel-fun x: return x

main:
    // Comment is needed, so that the spaces aren't removed.
/*^
  + SomeClass, main, global, toplevel-fun, null, true, false, return
  - member
*/
  some := SomeClass
/*        ^~~~~~~~~
  + SomeClass, ImportedClass, main, global, toplevel-fun, null, true, false
  - member
*/
  some.member
/*^~~~~~~~~~~
  + some
  - member
*/
  some.member
/*     ^~~~~~
  + member
  - some, SomeClass, toplevel-fun, ImportedClass, true, false, null
*/
  block := (:
       // Comment is needed so that the spaces aren't removed.
/*  ^
  + SomeClass, main, global, toplevel-fun, some, it, ImportedClass, null, true, false
  - member
*/
  )

  block.call
/*      ^~~~
  + call
  - member, ==, true, null, false
*/

  prefix.ImportedClass
/*       ^~~~~~~~~~~~~
  + ImportedClass, ImportedInterface, ImportedMixin
  - *
*/

  // Make sure it also works inside asserts
  assert: block.call
/*              ^~~~
  + call
  - member, ==, true, null, false
*/

  toplevel-fun 499
/*        ^~~~~~~~
  + toplevel-fun
  - main, global, SomeClass, null, true, false
*/

  toplevel-fun 499
/*         ^~~~~~~
  + toplevel-fun
  - main, global, SomeClass, null, true, false
*/
