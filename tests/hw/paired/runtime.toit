// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Reuse the platform-independent allocation and storage regression tests.
import .session
import ..ec618.gc as gc
import ..ec618.storage as storage
import ..ec618.storage-multipage as multipage
import ..ec618.float-format-ec618 as formats

run session/Session:
  session.run-case "GC self-test" --ms=60000:
    if session.is-testee: gc.main
  session.run-case "Storage self-test" --ms=60000:
    if session.is-testee: storage.main
  session.run-case "Multipage flash storage" --ms=60000:
    if session.is-testee: multipage.main
  session.run-case "Floating-point formatting" --ms=60000:
    if session.is-testee: formats.main
