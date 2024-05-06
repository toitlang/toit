// Copyright (C) 2021 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

class Instance:

  no-named:

  foo-argument --foo:

  optional-foo-argument --foo=null:

  either-argument --foo:

  either-argument --bar:

  foo-block-argument [--foo]:

  either-block-argument [--foo]:

  either-block-argument [--bar]:

  must-have-foo --foo:
  must-have-foo --bar --foo:

  need-not-have-foo --foo:
  need-not-have-foo --bar --foo=0:

  need-not-have-foo-2 --foo --bar:
  need-not-have-foo-2 --bar:

  lots-of-args --foo --bar --baz --fizz --buzz --fizz-buzz:

class Static:
  static no-named:

  static foo-argument --foo:

  static optional-foo-argument --foo=null:

  static either-argument --foo:

  static either-argument --bar:

  static foo-block-argument [--foo]:

  static either-block-argument [--foo]:

  static either-block-argument [--bar]:

  static must-have-foo --foo:
  static must-have-foo --bar --foo:

  static need-not-have-foo --foo:
  static need-not-have-foo --bar --foo=0:

  static need-not-have-foo-2 --foo --bar:
  static need-not-have-foo-2 --bar:

  static lots-of-args --foo --bar --baz --fizz --buzz --fizz-buzz:

main:
  instances
  statics

instances:
  a := Instance

  i1 := Instance --fizz=24  // Wrong argument name.

  a.no-named --bar=42  // Has no named arguments.

  a.foo-argument --foo=42  // No error.

  a.foo-argument --bar=42  // Has no argument named bar, foo missing.

  a.optional-foo-argument --bar=42  // Has no argument named bar.

  a.either-argument --foo=42  // No error.

  a.either-argument --bar=103  // No error.

  a.either-argument --foo=42 --bar=103  // Hard case. Currently no helpful message.

  a.no-named --foo=: it  // Has no (block) argument named foo.

  a.foo-argument --foo=: it  // Foo should be non-block.

  a.foo-argument --bar=: it  // Has no (block) argument named bar, foo missing.

  a.optional-foo-argument --bar=: it  // Has no (block) argument named bar.

  a.either-block-argument --foo=: it  // No error.

  a.either-block-argument --bar=: it  // No error.

  a.either-block-argument --foo=(: it) --bar=(:it)  // Hard case. Currently no helpful message.

  a.foo-argument --foo=: it  // Foo should be non-block.

  a.foo-block-argument --foo=42  // Foo should be a block.

  a.foo-argument  // Foo missing.

  a.optional-foo-argument  // No error - foo has a default.

  a.foo-block-argument  // Required argument not provided

  a.must-have-foo  // Missing foo.

  a.must-have-foo --bar  // Missing foo.

  a.need-not-have-foo --bar=42  // No error.

  a.need-not-have-foo  // Can always provide foo, but if not, must provide bar.

  a.need-not-have-foo-2 --bar=42  // No error.

  a.need-not-have-foo-2  // Missing bar.

  a.lots-of-args

statics:
  Static.no-named --bar=42  // Has no named arguments.

  Static.foo-argument --foo=42  // No error.

  Static.foo-argument --bar=42  // Has no argument named bar, foo missing.

  Static.optional-foo-argument --bar=42  // Has no argument named bar.

  Static.either-argument --foo=42  // No error.

  Static.either-argument --bar=103  // No error.

  Static.either-argument --foo=42 --bar=103  // Hard case. Currently no helpful message.

  Static.no-named --foo=: it  // Has no (block) argument named foo.

  Static.foo-argument --foo=: it  // Foo should be non-block.

  Static.foo-argument --bar=: it  // Has no (block) argument named bar, foo missing.

  Static.optional-foo-argument --bar=: it  // Has no (block) argument named bar.

  Static.either-block-argument --foo=: it  // No error.

  Static.either-block-argument --bar=: it  // No error.

  Static.either-block-argument --foo=(: it) --bar=(:it)  // Hard case. Currently no helpful message.

  Static.foo-argument --foo=: it  // Foo should be non-block.

  Static.optional-foo-argument --foo=: it  // Foo should be non-block.

  Static.foo-block-argument --foo=42  // Foo should be a block.

  Static.foo-argument  // Foo missing.

  Static.optional-foo-argument  // No error - foo has a default.

  Static.foo-block-argument  // Foo missing.

  Static.must-have-foo  // Missing foo.

  Static.must-have-foo --bar  // Missing foo.

  Static.need-not-have-foo --bar=42  // No error.

  Static.need-not-have-foo  // Can always provide foo, but if not, must provide bar.

  Static.need-not-have-foo-2 --bar=42  // No error.

  Static.need-not-have-foo-2  // Missing bar.

  Static.lots-of-args

