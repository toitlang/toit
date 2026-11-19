// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .global-assignment-prefixed-rename-test-dep as pre

// Test: assignments through an import prefix must be renamed.
main:
  pre.my-global = 2
/*
      @ a-write
      ^
  [a-def, a-write, a-plus, a-read]
*/
  pre.my-global += 2
/*
      @ a-plus
      ^
  [a-def, a-write, a-plus, a-read]
*/
  print pre.my-global
/*
            @ a-read
            ^
  [a-def, a-write, a-plus, a-read]
*/
