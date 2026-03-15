// Copyright (C) 2026 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Test: block parameter name
block-fun [my-block]:
/*
           ^
  my-block
*/
  my-block.call

main:
  block-fun: null
