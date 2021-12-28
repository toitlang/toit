// Copyright (C) 2020 Toitware ApS. All rights reserved.

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
  b := B
  b.foo
  bar
  global_field = 499
  (confuse b) is A
  (confuse a) as A
  (confuse a) is I
  (confuse b) as I
  a as A

main:
  bytecode_test
