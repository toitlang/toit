// Copyright (C) 2026 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Test: renaming a named parameter on one overloaded function should not
// affect identically named parameters on other overloads.

foo --some-name/int:
/*
       ^
  some-name
*/
  return some-name

foo --some-name/string [--if-error]:
/*
       ^
  some-name
*/
  result := some-name
  return result

bar --count/int:
/*
       ^
  count
*/
  return count

bar --count/int --extra/string:
  return count

main:
  foo --some-name=42
/*
         ^
  some-name
*/
  foo --some-name="hello" --if-error=: "error"
/*
         ^
  some-name
*/
  bar --count=3
/*
         ^
  count
*/
  bar --count=3 --extra="x"
