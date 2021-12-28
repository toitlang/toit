// Copyright (C) 2020 Toitware ApS. All rights reserved.

this_global := 499

class SomeClass:
  this_field := null

  constructor:
    this_local := 42
    this.this_field = 499
/*   ^
  + this, this_local, this_field, this_global
*/

  constructor.named1 x:
  constructor.named2 x:

  member:
    this_local := 499
    this.member
/*   ^
  + this, this_local, this_field, this_global
*/

  foo -> SomeClass: throw "foo"

  static statik:
    this_local := 42
    this_local
/*  ^~~~~~~~~~
  + this_local, this_global
  - this, this_field
*/

class Subclass extends SomeClass:
  constructor:
    super.named1 0
/*        ^~~~~~~~
  + named1, named2
  - *
*/
