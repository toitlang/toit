// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
See 'ble1-shared.toit'
*/

import .ble1-shared as shared

main:
  // Run twice to make sure the `close` works correctly.
  2.repeat:
    shared.main-central --iteration=it
    // Give the other side time to shut down.
    if it == 0: sleep --ms=500
