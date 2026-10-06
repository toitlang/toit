// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// Reuse the platform-independent allocation and storage regression tests.
import .session
import ..paired.runtime as runtime

main:
  session := Session
  try:
    runtime.run session
    session.finish
  finally:
    session.close
