// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

class A:
  x ::= 0

  foo .x:

main:
  (A).foo 1
