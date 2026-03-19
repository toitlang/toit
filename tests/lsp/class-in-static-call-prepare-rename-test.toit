// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Test: class name at static call site
class Foo:
  static bar -> int:
    return 42

call-it:
  Foo.bar
/*
  ^
  Foo
*/

main:
  call-it
