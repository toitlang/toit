// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.
// TEST_FLAGS: --force

confuse x -> any: return x
main:
  x := (confuse true) ? 1 : 0
  x.foo
