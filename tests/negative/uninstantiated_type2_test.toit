// Copyright (C) 2020 Toitware ApS. All rights reserved.

abstract class A:
  abstract toto

bar [block]: block.call
gee: return null

foo x/A:
  bar:
    x.toto

main:
  foo gee
