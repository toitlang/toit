// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// The program of prim-retry-test.cc: only its classes are used (lists,
// maps, byte-array and string slices, copy-on-write byte arrays).
main:
  list := [1, 2, 3]
  map := {"a": 1}
  bytes := #[1, 2, 3]
  slice := bytes[1..2]
  string-slice := "hello"[1..3]
  print "$list $map $bytes $slice $string-slice"
