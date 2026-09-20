// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Reuse the platform-independent allocation and storage regression tests.
import ..ec618.gc as gc
import ..ec618.storage as storage

main:
  gc.main
  storage.main
  print "All tests done"
