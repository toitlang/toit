// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Test: field-storing constructor parameter
class Holder:
  name/string
  constructor .name:
/*
               ^
  name
*/

main:
  Holder "hello"
