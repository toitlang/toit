// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

foo x -> none:
 #primitive.some.name

bar a b c d e f -> none:
  #primitive.core.string-hash-code

gee x -> none:
  #primitive.some.name: |a b|
    throw a

foobar x -> none:
  #primitive.core.name: |.a|
    throw a

foobar2 x -> none:
  #primitive.core.name: |a/int|
    throw a

foobar3 x -> none:
  #primitive.core.name: |a = 499|
    throw a

toto x -> none:
  #primitive.core.name.too-many: |a|
    throw a

tata x -> none:
  #primitive.intrinsics.not-existent

main:
  foo 1
  bar 1 2 3 4 5 6
  gee 1
  foobar 1
  toto 3
