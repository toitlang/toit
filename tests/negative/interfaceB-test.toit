// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

interface A:
  x := null

class B implements A:
  x := 499

main:
  b := B
