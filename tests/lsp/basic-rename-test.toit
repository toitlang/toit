// Copyright (C) 2026 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

foo x:
/*
^
  2
*/
  return x + 1

bar y:
  return y * 2

main:
  foo 42
/*^
  2
*/

  bar 10
/*^
  2
*/
