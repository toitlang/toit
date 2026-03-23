// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Test: renaming a named parameter on one overloaded function should only
// rename that overload's parameter definition, body usages, and matching
// call sites. The identically named parameter on the other overload must
// NOT be renamed.

foo --some-name/int:
/*
       ^
  3
*/
  return some-name

foo --some-name/string [--if-error]:
/*
       ^
  3
*/
  result := some-name
  return result

main:
  foo --some-name=42
/*
         ^
  3
*/
  foo --some-name="hello" --if-error=: "error"
/*
         ^
  3
*/
