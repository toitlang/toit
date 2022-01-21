// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

foo --x --y:
  return x + y * 2

foo2 x --y:
  return x + y * 2

foo3 --x y:
  return x + y * 2

bar --x [--b]:
  return x + 2 * b.call

bar2 x [--b]:
  return x + 2 * b.call

bar3 --x [b]:
  return x + 2 * b.call

bar4 [b] --x:
  return x + 2 * b.call

bar5 [--b] x:
  return x + 2 * b.call

class A:
  foo --x --y:
    return x + y * 2

  foo2 x --y:
    return x + y * 2

  foo3 --x y:
    return x + y * 2

  bar --x [--b]:
    return x + 2 * b.call

  bar2 x [--b]:
    return x + 2 * b.call

  bar3 --x [b]:
    return x + 2 * b.call

  bar4 [b] --x:
    return x + 2 * b.call

  bar5 [--b] x:
    return x + 2 * b.call

class B:
  foo x y=3:
    return x + y * 2

class C:
  foo --a --b --c [--d] [--e] [--f]:
    return  100_000 * a + 10_000 * b + 1000 * c + 100 * d.call + 10 * e.call + f.call
  foo2 --a b --c [--d] [e] [--f]:
    return  100_000 * a + 10_000 * b + 1000 * c + 100 * d.call + 10 * e.call + f.call
  foo3 --a b c [--d] [e] [f]:
    return  100_000 * a + 10_000 * b + 1000 * c + 100 * d.call + 10 * e.call + f.call

  bar --c --b --a [--f] [--e] [--d]:
    return  100_000 * a + 10_000 * b + 1000 * c + 100 * d.call + 10 * e.call + f.call
  bar2 --c b --a [--f] [e] [--d]:
    return  100_000 * a + 10_000 * b + 1000 * c + 100 * d.call + 10 * e.call + f.call
  bar3 c b --a [f] [e] [--d]:
    return  100_000 * a + 10_000 * b + 1000 * c + 100 * d.call + 10 * e.call + f.call

class D:
  foo --a=1 --b=2 --c=3 [--d] [--e] [--f]:
    return  100_000 * a + 10_000 * b + 1000 * c + 100 * d.call + 10 * e.call + f.call
  foo2 a=1 --b=2 c=3 [--d] [--e] [--f]:
    return  100_000 * a + 10_000 * b + 1000 * c + 100 * d.call + 10 * e.call + f.call
  foo3 --a=1 b=2 c=3 [--d] [e] [--f]:
    return  100_000 * a + 10_000 * b + 1000 * c + 100 * d.call + 10 * e.call + f.call
  foo4 --a=1 b=2 c=3 [--d] [e] [f]:
    return  100_000 * a + 10_000 * b + 1000 * c + 100 * d.call + 10 * e.call + f.call

  bar --c=3 --b=2 --a=1 [--f] [--e] [--d]:
    return  100_000 * a + 10_000 * b + 1000 * c + 100 * d.call + 10 * e.call + f.call
  bar2 --c=3 b=2 --a=1 [--f] [e] [--d]:
    return  100_000 * a + 10_000 * b + 1000 * c + 100 * d.call + 10 * e.call + f.call
  bar3 c=3 b=2 --a=1 [f] [e] [--d]:
    return  100_000 * a + 10_000 * b + 1000 * c + 100 * d.call + 10 * e.call + f.call

main:
  expect_equals 5 (foo --x=1 --y=2)
  expect_equals 5 (foo --y=2 --x=1)

  expect_equals 5 (foo2 1 --y=2)
  expect_equals 5 (foo2 --y=2 1)

  expect_equals 5 (foo3 --x=1 2)
  expect_equals 5 (foo3 2 --x=1)

  expect_equals 5 (bar --x=1 --b=: 2)
  expect_equals 5 (bar --b=(: 2) --x=1)
  expect_equals 5
      bar
          --b=: 2
          --x=1

  expect_equals 5 (bar2 1 --b=: 2)
  expect_equals 5 (bar2 --b=(: 2) 1)
  expect_equals 5
      bar2
          --b=: 2
          1

  expect_equals 5 (bar3 --x=1: 2)
  expect_equals 5 (bar3 (: 2) --x=1)
  expect_equals 5
      bar3
          (: 2)
          --x=1

  expect_equals 5 (bar4 --x=1: 2)
  expect_equals 5 (bar4 (: 2) --x=1)
  expect_equals 5
      bar4
          (: 2)
          --x=1

  expect_equals 5 (bar5 1 --b=:2)
  expect_equals 5 (bar5 --b=(: 2) 1)
  expect_equals 5
      bar5
          --b=: 2
          1

  a := A
  expect_equals 5 (a.foo --x=1 --y=2)
  expect_equals 5 (a.foo --y=2 --x=1)

  expect_equals 5 (a.foo2 1 --y=2)
  expect_equals 5 (a.foo2 --y=2 1)

  expect_equals 5 (a.foo3 --x=1 2)
  expect_equals 5 (a.foo3 2 --x=1)

  expect_equals 5 (a.bar --x=1 --b=: 2)
  expect_equals 5 (a.bar --b=(: 2) --x=1)
  expect_equals 5
      bar
          --b=: 2
          --x=1

  expect_equals 5 (a.bar2 1 --b=: 2)
  expect_equals 5 (a.bar2 --b=(: 2) 1)
  expect_equals 5
      bar2
          --b=: 2
          1

  expect_equals 5 (a.bar3 --x=1: 2)
  expect_equals 5 (a.bar3 (: 2) --x=1)
  expect_equals 5
      bar3
          (: 2)
          --x=1

  expect_equals 5 (a.bar4 --x=1: 2)
  expect_equals 5 (a.bar4 (: 2) --x=1)
  expect_equals 5
      bar4
          (: 2)
          --x=1

  expect_equals 5 (a.bar5 1 --b=: 2)
  expect_equals 5 (a.bar5 --b=(: 2) 1)
  expect_equals 5
      bar5
          --b=: 2
          1


  b := B
  expect_equals 5 (b.foo 1 2)
  expect_equals 7 (b.foo 1)

  c := C
  expect_equals 123456 (c.foo --a=1 --b=2 --c=3 --d=(:4) --e=(:5) --f=(:6))
  expect_equals 123456
      c.foo
         --a=1
         --b=2
         --c=3
         --d=: 4
         --e=: 5
         --f=: 6
  expect_equals 123456 (c.foo --c=3 --b=2 --a=1 --f=(:6) --e=(:5) --d=(:4))
  expect_equals 123456 (c.foo --f=(:6) --e=(:5) --d=(:4) --c=3 --b=2 --a=1)

  expect_equals 123456 (c.bar --a=1 --b=2 --c=3 --d=(:4) --e=(:5) --f=(:6))
  expect_equals 123456
      c.bar
         --a=1
         --b=2
         --c=3
         --d=: 4
         --e=: 5
         --f=: 6
  expect_equals 123456 (c.bar --c=3 --b=2 --a=1 --f=(:6) --e=(:5) --d=(:4))
  expect_equals 123456 (c.bar --f=(:6) --e=(:5) --d=(:4) --c=3 --b=2 --a=1)

  expect_equals 123456 (c.foo2 --f=(:6) 2 --d=(:4) --c=3 --a=1: 5)
  expect_equals 123456 (c.foo3 2 3 --d=(:4) --a=1 (: 5): 6)

  expect_equals 123456 (c.bar2 --f=(:6) 2 --d=(:4) --c=3 --a=1: 5)
  expect_equals 123456 (c.bar3 3 2 --d=(:4) --a=1 (: 6): 5)

  d := D
  expect_equals 123456 (d.foo --a=1 --b=2 --c=3 --d=(:4) --e=(:5) --f=(:6))
  expect_equals 123456 (d.foo --d=(:4) --e=(:5) --f=(:6))
  expect_equals 123456
      d.foo
         --a=1
         --c=3
         --d=: 4
         --e=: 5
         --f=: 6
  expect_equals 123456 (d.foo --c=3 --f=(:6) --e=(:5) --d=(:4))

  expect_equals 123456 (d.foo2 --f=(:6) --e=(:5) --d=(:4) --b=2 1)
  expect_equals 123456 (d.foo3 --f=(:6) 2 --d=(:4) --a=1: 5)
  expect_equals 123456 (d.foo4 2 --d=(:4) --a=1 (: 5): 6)

  expect_equals 123456 (d.bar --f=(:6) --e=(:5) --d=(:4))
  expect_equals 123456 (d.bar --a=1 --c=3 --d=(:4) --e=(:5) --f=(:6))
  expect_equals 123456
      d.bar
         --a=1
         --b=2
         --d=: 4
         --e=: 5
         --f=: 6
  expect_equals 123456 (d.bar --b=2 --a=1 --f=(:6) --e=(:5) --d=(:4))
  expect_equals 123456 (d.bar --f=(:6) --e=(:5) --d=(:4) --c=3)

  expect_equals 123456 (d.bar2 --f=(:6) --d=(:4) --c=3 --a=1: 5)
  expect_equals 123456 (d.bar3 3 --d=(:4) --a=1 (: 6): 5)
