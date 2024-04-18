// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

interface A:
  foo

interface A2:
  bar x

class B implements A A2:
  foo: "foo"

main:
  b := B
