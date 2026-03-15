// Copyright (C) 2026 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

foo param/int:
/*  ^
    param
*/
  return param + 1

bar y:
  local-var := y * 2
/*^
    local-var
*/
  return local-var

main:
  foo 42
  bar 10
