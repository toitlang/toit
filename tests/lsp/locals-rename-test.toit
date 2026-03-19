// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

foo param/int:
/*
    ^
    2
*/
  return param + 1

bar y:
  local-var := y * 2
/*
  ^
    2
*/
  return local-var
/*
         ^
    2
*/

main:
  foo 42
  bar 10
