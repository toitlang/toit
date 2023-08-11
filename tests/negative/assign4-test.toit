// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

class class A:
  abstract bar= x

class B extends A:
  bar= x:
    super = 22

main:
  B.bar = 42
