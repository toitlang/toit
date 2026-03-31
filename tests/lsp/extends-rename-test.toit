// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Test: renaming a class also updates extends clauses.
class Foo:
/*
      @ Foo
      ^
  [Foo, Holder.extends.Foo, make.return.Foo, make.ctor.Foo]
*/
  field := 0

class Holder extends Foo:
/*                   @ Holder.extends.Foo */
  field := 1

make -> Foo:
/*      @ make.return.Foo */
  return Foo
/*       @ make.ctor.Foo */

main:
  make
