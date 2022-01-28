// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .static_completion_test as prefix

class Foo:
  static mem_static:
  static this_static:
  member:
  this_member:

  static bar:
    mem_static
/*  ^~~~~~~~~~
  + mem_static
  - member, this_member
*/
    this_static
/*  ^~~~~~~~~~~
  + this_static
  - member, this_member
*/

  constructor:
    member
/*  ^~~~~~
  + member, mem_static
*/
    this_member
/*      ^~~~~~~
  + this_member, this_static, this
*/

  constructor.factory:
    mem_static
/*     ^~~~~~~
  + mem_static
  - member, this_member
*/
    this_static
/*      ^~~~~~~
  + this_static
  - member, this_member
*/
    return Foo

main:
  Foo
  Foo.factory
