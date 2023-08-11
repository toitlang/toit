// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Once there is a default value, all must be default.
foo x=499 y:
  return x + unresolved

main:
  foo 1 2
