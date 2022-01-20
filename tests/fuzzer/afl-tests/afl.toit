// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

foo fun: return fun.call

bar [block]: block.call

gee x/int y/int:
  return x + y

gee --name [--named] -> any:
  return named.call name

/**
toitdoc comment $x and $y
ref $gee
*/
bar x=12 y/string="str":
  return "$x $y"

class A:
  field := ?
  constructor:
    field = null
  constructor x:
    field = x
  constructor .field y:
    field += y

class B extends A:
  constructor:
    return B.named
  constructor.named:
    super

  static fun x/int -> none:
    gee 1 2

  static static_field := 499

  instance:
    return instance --name=:: 2

  instance x y/int -> none:
    instance

  instance --name:
    name.call

global := 12
    
main:
  x := 499
  foo:: x + it

  bar: continue.bar 11

  while foo (:: it):
    for i := 0; i < 49; i++:
      if true:
        gee 1 2
      else:
        gee 3 4
  try:
    gee 499 1
  finally:
    gee 1 2

  gee --name=12 --named=: it
  
  gee --name=12 --named=:
    it + 1
