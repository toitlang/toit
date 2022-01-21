// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.
// TEST_FLAGS: --force

class A:
  field / string
  constructor .field:

main:
  (A "str").field = "can't assign to final"
