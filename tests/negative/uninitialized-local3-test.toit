// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

class A:
  constructor.named x:

confuse x: return x

class B extends A:
  constructor:
    local := ?
    if (confuse false):
      local = 1
    super.named local

main:
