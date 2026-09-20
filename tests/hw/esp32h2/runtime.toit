// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Reuse the platform-independent allocation and storage regression tests.
import .session
import ..ec618.gc as gc
import ..ec618.storage as storage

main:
  session := Session
  try:
    session.run-case "GC self-test" --ms=60000:
      if IS-TESTEE: gc.main
    session.run-case "Storage self-test" --ms=60000:
      if IS-TESTEE: storage.main
    session.finish
  finally:
    session.close
