// Copyright (C) 2021 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

class Instance:
  constructor.constructor-no-arguments:

  constructor.constructor-one-argument x:

  constructor.constructor-one-or-three-arguments x:
  constructor.constructor-one-or-three-arguments x y z:

  constructor.constructor-foo-argument --foo:

  zero:
  one x:
  two x y:
  three x y z:

  zero-unnamed --x:

  one-or-three x:
  one-or-three x y z:

  one-or-three --foo x:
  one-or-three --bar x y z:

  takes-a-block [block]:
  doesnt-take-a-block:
  doesnt-take-a-block x:
  takes-two-blocks [block1] [block2]:

  doesnt-take-an-unnamed-block [--block]:

  one-or-three-blocks [block1]:
  one-or-three-blocks [block1] [block2] [block3]:

  takes-a-named-block [--block]:

  my-setter= x:

  calls-one-or-three:
    one-or-three 1 2
    one-or-three-blocks (: ) (: )

class Static:
  static zero:
  static one x:
  static two x y:
  static three x y z:

  static zero-unnamed --x:

  static one-or-three x:
  static one-or-three x y z:

  static takes-a-block [block]:
  static doesnt-take-a-block:
  static doesnt-take-a-block x:
  static takes-two-blocks [block1] [block2]:

  static doesnt-take-an-unnamed-block [--block]:

  static one-or-three-blocks [block1]:
  static one-or-three-blocks [block1] [block2] [block3]:

  static takes-a-named-block [--block]:

  static my-setter= x:

  calls-one-or-three:
    one-or-three 1 2
    one-or-three-blocks (: ) (: )

  static static-calls-one-or-three:
    one-or-three 1 2
    one-or-three-blocks (: ) (: )

main:
  instances
  statics

instances:
  a := Instance

  i1 := Instance.constructor-no-arguments 42  // Too many arguments.
  i2 := Instance.constructor-one-argument  // Too few arguments.
  i3 := Instance.constructor-one-argument 42 103  // Too many arguments.
  i4 := Instance.constructor-one-or-three-arguments  // Too few arguments.
  i5 := Instance.constructor-one-or-three-arguments 42 103  // No overload with two arguments.
  i6 := Instance.constructor-one-or-three-arguments 42 103 0 1 // Too many arguments.
  i7 := Instance.constructor-foo-argument  // Missing named argument.

  a.zero 1
  a.one
  a.one 1 2
  a.two
  a.two 1
  a.two 1 2 3
  a.three
  a.three 1
  a.three 1 2
  a.three 1 2 3 4
  a.one-or-three
  a.one-or-three 1 2
  a.one-or-three 1 2 3 4

  a.takes-a-block
  a.takes-a-block (: ) (: )
  a.takes-a-block --block=:
    it

  a.doesnt-take-a-block:
    it
  a.doesnt-take-a-block 42:
    it

  a.takes-a-named-block:
    it

  a.takes-two-blocks
  a.takes-two-blocks:
    it

  a.doesnt-take-an-unnamed-block:
    it
  a.zero-unnamed 1

  a.one-or-three-blocks

  a.one-or-three-blocks (: ) (: )

  a.one-or-three-blocks (: ) (: ) (: ) (: )

  a.missing-setter = 5

  a.my-setter

  a.zero = 42

statics:
  Static.zero 1
  Static.one
  Static.one 1 2
  Static.two
  Static.two 1
  Static.two 1 2 3
  Static.three
  Static.three 1
  Static.three 1 2
  Static.three 1 2 3 4
  Static.one-or-three
  Static.one-or-three 1 2
  Static.one-or-three 1 2 3 4

  Static.takes-a-block
  Static.takes-a-block (: ) (: )
  Static.takes-a-block --block=:
    it

  Static.doesnt-take-a-block:
    it
  Static.doesnt-take-a-block 42:
    it

  Static.takes-a-named-block:
    it

  Static.takes-two-blocks
  Static.takes-two-blocks:
    it

  Static.doesnt-take-an-unnamed-block:
    it
  Static.zero-unnamed 1

  Static.one-or-three-blocks

  Static.one-or-three-blocks (: ) (: )

  Static.one-or-three-blocks (: ) (: ) (: ) (: )

  Static.missing-setter = 5

  Static.my-setter

  Static.zero = 42
