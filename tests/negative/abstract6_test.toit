// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

class A:
  foo:
    return "A"

abstract class B extends A:
  abstract foo

class C extends B:

main:
  (C).foo
