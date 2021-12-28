// Copyright (C) 2019 Toitware ApS. All rights reserved.

import .completion_imported
import .completion_imported as prefix

class SomeClass:
  member:

global := 499

toplevel_fun x: return x

main:
    // Comment is needed, so that the spaces aren't removed.
/*^
  + SomeClass, main, global, toplevel_fun, null, true, false, return
  - member
*/
  some := SomeClass
/*        ^~~~~~~~~
  + SomeClass, ImportedClass, main, global, toplevel_fun, null, true, false
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
  - some, SomeClass, toplevel_fun, ImportedClass, true, false, null
*/
  block := (:
       // Comment is needed so that the spaces aren't removed.
/*  ^
  + SomeClass, main, global, toplevel_fun, some, it, ImportedClass, null, true, false
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
  + ImportedClass, ImportedInterface
  - *
*/
