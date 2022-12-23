// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

interface I:

class A implements I:
  foo: print "A.foo"

class B:
  foo: print "B.foo"

bar: print "global bar"

global_field := 42

confuse x: return x

bytecode_test:
  a := A
  a.foo
  (confuse a).foo
  b := B
  b.foo
  (confuse b).foo
  bar
  global_field = 499
  (confuse b) is A
  (confuse a) as A
  (confuse a) is I
  (confuse b) as I
  a as A

main:
  bytecode_test
