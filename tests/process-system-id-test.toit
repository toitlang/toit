// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

main:
  system-id := SYSTEM-PROCESS-ID_
  expect system-id >= 0
  expect-equals system-id process-system-id_
  // Applications run in their own process, not in the system process.
  expect-not-equals Process.current.id system-id
  // The system process is alive.
  expect (process-get-priority_ system-id) >= 0
