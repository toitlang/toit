// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

abstract class A:
  abstract toto

bar [block]: block.call
gee: return null

foo x/A:
  bar:
    x.toto

main:
  foo gee
