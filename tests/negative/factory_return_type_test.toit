// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

class A:
  constructor:

  constructor.factory -> A:
    return A

  constructor.factory2 x -> B:
    return B

class B extends A:

main:
  A
  A.factory
  A.factory2 499
