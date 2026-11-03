// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

// Native executables can only run the programs that are compiled into them,
// so launching any other program fails before anything is set up for it.

main:
  expect-throw "UNSUPPORTED": launch_ #[1, 2, 3] 0 (ByteArray 16) []

launch_ bytes/ByteArray gid/int id/ByteArray arguments:
  #primitive.snapshot.launch
