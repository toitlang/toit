// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Regression test for https://github.com/toitlang/toit/issues/2950.
// A global initializer whose body contains an assignment to the global
// being initialized must not crash the type checker. The global's
// `return_type` has not been computed yet, so the type checker has to
// handle the invalid receiver type gracefully.

just-block [block] -> int: return 1
store-lambda fn/Lambda -> int: return 1

some-global := just-block: some-global = some-global
some-global2 := store-lambda:: some-global2 = some-global2

main:
  some-global
  some-global2
