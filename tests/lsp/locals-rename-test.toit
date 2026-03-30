// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

foo param/int:
/*  @ param-def */
/*
    ^
    [param-def, param-usage]
*/
  return param + 1
/*       @ param-usage */

bar y:
  local-var := y * 2
/*@ local-def */
/*
  ^
    [local-def, local-usage]
*/
  return local-var
/*       @ local-usage */
/*
         ^
    [local-def, local-usage]
*/

main:
  foo 42
  bar 10
