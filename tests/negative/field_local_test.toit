// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

foo x:

class A:
  field := x := 499
  instance:
    foo x   // The x of the field initializer must not be visible here.

main:
  (A).instance
