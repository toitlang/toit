// Copyright (C) 2021 Toitware ApS. All rights reserved.

class Instance:
  constructor.constructor_no_arguments:

  constructor.constructor_one_argument x:

  constructor.constructor_one_or_three_arguments x:
  constructor.constructor_one_or_three_arguments x y z:

  constructor.constructor_foo_argument --foo:

  zero:
  one x:
  two x y:
  three x y z:

  zero_unnamed --x:

  one_or_three x:
  one_or_three x y z:

  takes_a_block [block]:
  doesnt_take_a_block:
  doesnt_take_a_block x:
  takes_two_blocks [block1] [block2]:

  doesnt_take_an_unnamed_block [--block]:

  one_or_three_blocks [block1]:
  one_or_three_blocks [block1] [block2] [block3]:

  takes_a_named_block [--block]:

  my_setter= x:

  calls_one_or_three:
    one_or_three 1 2
    one_or_three_blocks (: ) (: )

class Static:
  static zero:
  static one x:
  static two x y:
  static three x y z:

  static zero_unnamed --x:

  static one_or_three x:
  static one_or_three x y z:

  static takes_a_block [block]:
  static doesnt_take_a_block:
  static doesnt_take_a_block x:
  static takes_two_blocks [block1] [block2]:

  static doesnt_take_an_unnamed_block [--block]:

  static one_or_three_blocks [block1]:
  static one_or_three_blocks [block1] [block2] [block3]:

  static takes_a_named_block [--block]:

  static my_setter= x:

  calls_one_or_three:
    one_or_three 1 2
    one_or_three_blocks (: ) (: )

  static static_calls_one_or_three:
    one_or_three 1 2
    one_or_three_blocks (: ) (: )

main:
  instances
  statics

instances:
  a := Instance

  i1 := Instance.constructor_no_arguments 42  // Too many arguments.
  i2 := Instance.constructor_one_argument  // Too few arguments.
  i3 := Instance.constructor_one_argument 42 103  // Too many arguments.
  i4 := Instance.constructor_one_or_three_arguments  // Too few arguments.
  i5 := Instance.constructor_one_or_three_arguments 42 103  // No overload with two arguments.
  i6 := Instance.constructor_one_or_three_arguments 42 103 0 1 // Too many arguments.
  i7 := Instance.constructor_foo_argument  // Missing named argument.

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
  a.one_or_three
  a.one_or_three 1 2
  a.one_or_three 1 2 3 4

  a.takes_a_block
  a.takes_a_block (: ) (: )
  a.takes_a_block --block=:
    it

  a.doesnt_take_a_block:
    it
  a.doesnt_take_a_block 42:
    it

  a.takes_a_named_block:
    it

  a.takes_two_blocks
  a.takes_two_blocks:
    it

  a.doesnt_take_an_unnamed_block:
    it
  a.zero_unnamed 1

  a.one_or_three_blocks

  a.one_or_three_blocks (: ) (: )

  a.one_or_three_blocks (: ) (: ) (: ) (: )

  a.missing_setter = 5

  a.my_setter

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
  Static.one_or_three
  Static.one_or_three 1 2
  Static.one_or_three 1 2 3 4

  Static.takes_a_block
  Static.takes_a_block (: ) (: )
  Static.takes_a_block --block=:
    it

  Static.doesnt_take_a_block:
    it
  Static.doesnt_take_a_block 42:
    it

  Static.takes_a_named_block:
    it

  Static.takes_two_blocks
  Static.takes_two_blocks:
    it

  Static.doesnt_take_an_unnamed_block:
    it
  Static.zero_unnamed 1

  Static.one_or_three_blocks

  Static.one_or_three_blocks (: ) (: )

  Static.one_or_three_blocks (: ) (: ) (: ) (: )

  Static.missing_setter = 5

  Static.my_setter

  Static.zero = 42
