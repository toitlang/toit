// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

interface A:
  foo

interface A2 implements A:
  bar x

class B implements A2:
  bar x: "bar"

main:
  b := B
