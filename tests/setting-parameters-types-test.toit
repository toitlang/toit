// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

class A:
  x / string? := null
  y / any := null
  z := null

  constructor.x .x:

  constructor.y .y:
  constructor.y2 .y/string:
  constructor.y3 .y/any:

  constructor.z .z:
  constructor.z2 .z/string:

  constructor.x --named/bool .x:

  constructor.y --named/bool .y:
  constructor.y2 --named/bool .y/string:
  constructor.y3 --named/bool .y/any:

  constructor.z --named/bool .z:
  constructor.z2 --named/bool .z/string:

  constructor.not-setting x:

  foo .x:  // NO-WARN

  bar .y:  // NO-WARN
  bar2 .y/string:  // NO-WARN
  bar3 .y/any:  // NO-WARN

  gee .z:  // NO-WARN
  gee2 .z/string:  // NO-WARN

  foo --named/bool .x:  // NO-WARN

  bar --named/bool .y:  // NO-WARN
  bar2 --named/bool .y/string:  // NO-WARN
  bar3 --named/bool .y/any:  // NO-WARN

  gee --named/bool .z:  // NO-WARN
  gee2 --named/bool .z/string:  // NO-WARN

main:
  a := A.not-setting "foo"

  a = A.x "foo"
  a = A.y 499
  a = A.y2 "foo"
  a = A.y3 true
  a = A.z 499
  a = A.z2 "foo"

  a = A.x --named "foo"
  a = A.y --named 499
  a = A.y2 --named "foo"
  a = A.y3 --named true
  a = A.z --named 499
  a = A.z2 --named "foo"

  a.foo "foo"
  a.bar 499
  a.bar2 "foo"
  a.bar3 true
  a.gee 499
  a.gee2 "foo"

  a.foo --named "foo"
  a.bar --named 499
  a.bar2 --named "foo"
  a.bar3 --named true
  a.gee --named 499
  a.gee2 --named "foo"
