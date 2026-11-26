// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import system

// Spawns many short-lived processes that allocate, so that processes are
// terminated and deleted while process-chunk-walk-test walks the processes'
// heap chunks from another thread.
main:
  400.repeat: | round |
    spawn::
      retained := List 20: ByteArray 200 --initial=round
      system.process-stats --gc
      if retained[3][0] != (round & 0xff): throw "GC_CORRUPTED_VALUE"
    if round % 16 == 0: sleep --ms=1
