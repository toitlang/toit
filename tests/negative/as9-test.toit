// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

confuse x -> any: return x
class A:
main:
  a := A
  a = confuse null
  a as A
