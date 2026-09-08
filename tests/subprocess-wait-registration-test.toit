// Copyright (C) 2026 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import host.pipe
import system show platform PLATFORM-FREERTOS

SIGKILL ::= 9

main:
  // FreeRTOS cannot launch host subprocesses.
  if platform == PLATFORM-FREERTOS: return

  25.repeat:
    process := pipe.fork --create-stdin "cat" ["cat"]

    // Native signaling failures must reach the caller. Signal 999 is outside
    // the supported range and cannot be delivered on any host platform.
    error := catch: pipe.kill_ process.pid 999
    expect-equals "INVALID_ARGUMENT" error

    // This is what a retry after an interrupted wait does at the native
    // boundary. It must not link the subprocess resource more than once.
    wait-for_ process.pid
    wait-for_ process.pid

    pipe.kill_ process.pid SIGKILL
    exit-value := with-timeout --ms=1_000: process.wait
    expect-equals SIGKILL (pipe.exit-signal exit-value)

wait-for_ subprocess -> none:
  #primitive.subprocess.wait-for
