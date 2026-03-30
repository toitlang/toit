// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Test: renaming a class that appears in type annotations should find
// all usages including type annotations and return types.

class Foo:
/*    @ def */
/*
      ^
  [def, param-type, return-type, instantiation]
*/

compute param/Foo -> Foo:
/*            @ param-type */
/*                   @ return-type */
  return param

main:
  compute Foo
/*        @ instantiation */
