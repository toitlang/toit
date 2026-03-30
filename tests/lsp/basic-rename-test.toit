// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

foo x:
/*
@ foo-def */
/*
^
  [foo-def, foo-call]
*/
  return x + 1

bar y:
/*
@ bar-def */
  return y * 2

main:
  foo 42
/*@ foo-call */
/*
  ^
  [foo-def, foo-call]
*/

  bar 10
/*@ bar-call */
/*
  ^
  [bar-def, bar-call]
*/
