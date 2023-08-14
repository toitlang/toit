// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .confuse

interface I:

class A implements I:
  foo: print "A.foo"

class B:
  foo: print "B.foo"

bar: print "global bar"

global-field := 42

bytecode-test:
  a := A
  a.foo
  (confuse a).foo
  b := B
  b.foo
  (confuse b).foo
  bar
  global-field = 499
  (confuse b) is A
  (confuse a) as A
  (confuse a) is I
  (confuse b) as I
  a as A

main:
  bytecode-test
