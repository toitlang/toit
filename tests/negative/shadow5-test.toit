// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

foo f:

main:
  x := 0
  for x := 1; x < 10; x++:
    foo:: x
