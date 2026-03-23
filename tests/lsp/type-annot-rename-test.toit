// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Test: renaming a class that appears in type annotations should find
// all usages including type annotations and return types.

class Foo:
/*
      ^
  4
*/

compute param/Foo -> Foo:
  return param

main:
  compute Foo
