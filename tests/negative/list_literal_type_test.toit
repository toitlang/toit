// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

main:
  [].foo
  [1].foo
  [1, 2, 3, 4].foo
  [300].foo
  [1, 2, 3, 4, 300].foo
  unresolved
