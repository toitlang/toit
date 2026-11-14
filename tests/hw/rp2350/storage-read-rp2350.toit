// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
import .storage-common show verify-persistent

main:
  // This image never writes the fixtures: it must follow the writer image.
  verify-persistent
  print "storage-read-rp2350: PASS persistent data survived firmware replacement"
