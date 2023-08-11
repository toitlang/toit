// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

abstract class A:
  abstract foo

class B extends A:
  foo x:

main:
  (B).foo 499
