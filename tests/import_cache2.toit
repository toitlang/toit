// Copyright (C) 2020 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .import_cache1  // Transitively should get 'bar'

// Important that we have an `export *`.
// This makes the compiler cache lookup-results.
export *

foo:
  // This is the real test: we must be able to resolve 'bar' here.
  // Specifically: when looking in .import_cache1 for 'bar', it must find
  // it.
  bar
  // Same is true for core-types.
  // When looking at the module from the outside, the `int` check won't succeed, but
  //   from within, it must.
  local /int := 499
