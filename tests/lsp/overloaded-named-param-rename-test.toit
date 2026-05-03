// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Test: renaming a named parameter on one overloaded function should only
// rename that overload's parameter definition, body usages, and matching
// call sites. The identically named parameter on the other overload must
// NOT be renamed.

foo --some-name/int:
/*
      @ int-def
       ^
  [int-def, int-body, int-call]
*/
  return some-name
/*       @ int-body */

foo --some-name/string [--if-error]:
/*
      @ str-def
       ^
  [str-def, str-body, str-call]
*/
  result := some-name
/*          @ str-body */
  return result

main:
  foo --some-name=42
/*
        @ int-call
         ^
  [int-def, int-body, int-call]
*/
  foo --some-name="hello" --if-error=: "error"
/*
        @ str-call
         ^
  [str-def, str-body, str-call]
*/
