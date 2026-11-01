// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ..confuse

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

run-block [block]:
  block.call

after-wide-return:
  print "after"

// Returns from a block when there are enough locals on the stack to need
// the wide variant of the non-local return bytecode. There is more code
// in the block, so we can see where the bytecode ends.
wide-return-test:
  x0 := confuse 0
  x1 := confuse 1
  x2 := confuse 2
  x3 := confuse 3
  x4 := confuse 4
  x5 := confuse 5
  x6 := confuse 6
  x7 := confuse 7
  x8 := confuse 8
  x9 := confuse 9
  x10 := confuse 10
  x11 := confuse 11
  x12 := confuse 12
  x13 := confuse 13
  x14 := confuse 14
  x15 := confuse 15
  run-block:
    if confuse x0: return
    after-wide-return
  print x0 + x1 + x2 + x3 + x4 + x5 + x6 + x7 + x8 + x9 + x10 + x11 + x12 + x13 + x14 + x15

main:
  bytecode-test
  wide-return-test
