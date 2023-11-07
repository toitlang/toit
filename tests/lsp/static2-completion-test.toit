// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .static-completion-test as prefix

class Foo:
  static mem-static:
  static this-static:
  member:
  this-member:

  static bar:
    mem-static
/*  ^~~~~~~~~~
  + mem-static
  - member, this-member
*/
    this-static
/*  ^~~~~~~~~~~
  + this-static
  - member, this-member
*/

  constructor:
    member
/*  ^~~~~~
  + member, mem-static
*/
    this-member
/*      ^~~~~~~
  + this-member, this-static, this
*/

  constructor.factory:
    mem-static
/*     ^~~~~~~
  + mem-static
  - member, this-member
*/
    this-static
/*      ^~~~~~~
  + this-static
  - member, this-member
*/
    return Foo

main:
  Foo
  Foo.factory
