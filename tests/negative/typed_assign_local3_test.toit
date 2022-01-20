// Copyright (C) 2020 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.
// TEST_FLAGS: --force

class A:
  operator + x/int -> int:
    return x

main:
  a /A := A
  a++
