// Copyright (C) 2026 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Test: return and this should be null
class Foo:
  method:
    return this
/*
    ^
  null
*/

main:
  Foo
