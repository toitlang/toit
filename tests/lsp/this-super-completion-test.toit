// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

this-global := 499

class SomeClass:
  this-field := null

  constructor:
    this-local := 42
    this.this-field = 499
/*   ^
  + this, this-local, this-field, this-global
*/

  constructor.named1 x:
  constructor.named2 x:

  constructor.named-arg --x --y:
  constructor.named-arg --x --y --z:

  member:
    this-local := 499
    this.member
/*   ^
  + this, this-local, this-field, this-global
*/

  foo -> SomeClass: throw "foo"

  static statik:
    this-local := 42
    this-local
/*  ^~~~~~~~~~
  + this-local, this-global
  - this, this-field
*/

class Subclass extends SomeClass:
  constructor:
    super.named1 0
/*        ^~~~~~~~
  + named1, named2, named-arg
  - *
*/

  constructor.other:
    super.named-arg --x=3 --y=4
/*                    ^~~~~~~~~
  + x=, y=, z=
  - *
*/

  constructor.other2:
  // In theory we would like to only see 'z', but at the moment we also
  // suggest namest that are already used.
  // When fixed, remove the "x, y, " below.
    super.named-arg --x=3 --y=5 --z=3
/*                                ^~~
+ x=, y=, z=
- *
*/
