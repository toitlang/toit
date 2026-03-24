// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Test: type annotation with class name.
class Foo:
  constructor:

typed param/Foo:
/*          ^
  Foo
*/
  null

main:
  typed Foo
