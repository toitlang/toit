// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

interface I:

class A implements I:

class B:
  x / I? := null

  gee arg:
    // This virtual field-store will be optimized to a direct
    // static field-store.
    // The typecheck for the interface must work correctly.
    x = arg

main:
  b := B
  b.gee A
  b.gee "str"
