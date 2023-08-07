// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

this_global := 499

class SomeClass:
  this_field := null

  constructor:
    this_local := 42
    this.this_field = 499
/*   ^
  + this, this-local, this-field, this-global
*/

  constructor.named1 x:
  constructor.named2 x:

  member:
    this_local := 499
    this.member
/*   ^
  + this, this-local, this-field, this-global
*/

  foo -> SomeClass: throw "foo"

  static statik:
    this_local := 42
    this_local
/*  ^~~~~~~~~~
  + this-local, this-global
  - this, this-field
*/

class Subclass extends SomeClass:
  constructor:
    super.named1 0
/*        ^~~~~~~~
  + named1, named2
  - *
*/
