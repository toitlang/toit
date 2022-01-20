// Copyright (C) 2019 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

abstract class A:
  abstract foo

class B extends A:
  abstract bar x

class C extends B:
  abstract gee x y

main:
  C
