// Copyright (C) 2021 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

class Instance:

  no_named:

  foo_argument --foo:

  optional_foo_argument --foo=null:

  either_argument --foo:

  either_argument --bar:

  foo_block_argument [--foo]:

  either_block_argument [--foo]:

  either_block_argument [--bar]:

  must_have_foo --foo:
  must_have_foo --bar --foo:

  need_not_have_foo --foo:
  need_not_have_foo --bar --foo=0:

  need_not_have_foo_2 --foo --bar:
  need_not_have_foo_2 --bar:

  lots_of_args --foo --bar --baz --fizz --buzz --fizz_buzz:

class Static:
  static no_named:

  static foo_argument --foo:

  static optional_foo_argument --foo=null:

  static either_argument --foo:

  static either_argument --bar:

  static foo_block_argument [--foo]:

  static either_block_argument [--foo]:

  static either_block_argument [--bar]:

  static must_have_foo --foo:
  static must_have_foo --bar --foo:

  static need_not_have_foo --foo:
  static need_not_have_foo --bar --foo=0:

  static need_not_have_foo_2 --foo --bar:
  static need_not_have_foo_2 --bar:

  static lots_of_args --foo --bar --baz --fizz --buzz --fizz_buzz:

main:
  instances
  statics

instances:
  a := Instance

  i1 := Instance --fizz=24  // Wrong argument name.

  a.no_named --bar=42  // Has no named arguments.

  a.foo_argument --foo=42  // No error.

  a.foo_argument --bar=42  // Has no argument named bar, foo missing.

  a.optional_foo_argument --bar=42  // Has no argument named bar.

  a.either_argument --foo=42  // No error.

  a.either_argument --bar=103  // No error.

  a.either_argument --foo=42 --bar=103  // Hard case. Currently no helpful message.

  a.no_named --foo=: it  // Has no (block) argument named foo.

  a.foo_argument --foo=: it  // Foo should be non-block. Currently no helpful message.

  a.foo_argument --bar=: it  // Has no (block) argument named bar, foo missing.

  a.optional_foo_argument --bar=: it  // Has no (block) argument named bar.

  a.either_block_argument --foo=: it  // No error.

  a.either_block_argument --bar=: it  // No error.

  a.either_block_argument --foo=(: it) --bar=(:it)  // Hard case. Currently no helpful message.

  a.foo_argument --foo=: it  // Foo should be non-block. Currently no helpful message.

  a.foo_block_argument --foo=42  // Foo should be a block.  Currently no helpful message.

  a.foo_argument  // Foo missing.

  a.optional_foo_argument  // No error - foo has a default.

  a.foo_block_argument  // Required argument not provided

  a.must_have_foo  // Missing foo.

  a.must_have_foo --bar  // Missing foo.

  a.need_not_have_foo --bar=42  // No error.

  a.need_not_have_foo  // Hard case. Currently no helpful message.

  a.need_not_have_foo_2 --bar=42  // No error.

  a.need_not_have_foo_2  // Missing bar.

  a.lots_of_args

statics:
  Static.no_named --bar=42  // Has no named arguments.

  Static.foo_argument --foo=42  // No error.

  Static.foo_argument --bar=42  // Has no argument named bar, foo missing.

  Static.optional_foo_argument --bar=42  // Has no argument named bar.

  Static.either_argument --foo=42  // No error.

  Static.either_argument --bar=103  // No error.

  Static.either_argument --foo=42 --bar=103  // Hard case. Currently no helpful message.

  Static.no_named --foo=: it  // Has no (block) argument named foo.

  Static.foo_argument --foo=: it  // Foo should be non-block. Currently no helpful message.

  Static.foo_argument --bar=: it  // Has no (block) argument named bar, foo missing.

  Static.optional_foo_argument --bar=: it  // Has no (block) argument named bar.

  Static.either_block_argument --foo=: it  // No error.

  Static.either_block_argument --bar=: it  // No error.

  Static.either_block_argument --foo=(: it) --bar=(:it)  // Hard case. Currently no helpful message.

  Static.foo_argument --foo=: it  // Foo should be non-block. Currently no helpful message.

  Static.optional_foo_argument --foo=: it  // Foo should be non-block. Currently no helpful message.

  Static.foo_block_argument --foo=42  // Foo should be a block. Currently no helpful message.

  Static.foo_argument  // Foo missing.

  Static.optional_foo_argument  // No error - foo has a default.

  Static.foo_block_argument  // Foo missing.

  Static.must_have_foo  // Missing foo.

  Static.must_have_foo --bar  // Missing foo.

  Static.need_not_have_foo --bar=42  // No error.

  Static.need_not_have_foo  // Hard case. Currently no helpful message.

  Static.need_not_have_foo_2 --bar=42  // No error.

  Static.need_not_have_foo_2  // Missing bar.

  Static.lots_of_args

