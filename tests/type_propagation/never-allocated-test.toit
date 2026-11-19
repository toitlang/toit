// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// The classes that are never allocated in this program, like the copy-on-write
// byte arrays, are not to be analyzed even though the 'any' type and the type
// checks on it include them. Their fields have no types, so the first pass of
// the propagator used to find that their methods do not return and code that
// follows calls to them was removed. The optimizer also changed the methods,
// so in the second pass they appeared to return and the propagator ran off
// the end of the calling method. It only happens when propagating types for
// optimized programs. The shape of the code matters, so please don't tidy it.

glob := (::
).call

class A:
  lambda ::= ?
  field := (::
  ).call

  constructor:
    x := 0
    lambda = (:: x++)

  method:

test lambda:

main:
  test (A).method
