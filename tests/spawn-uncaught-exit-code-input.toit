// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// The program of spawn-uncaught-exit-code-test-compiler.toit: a spawned
// process dies with an uncaught exception while the main process and a few
// other spawned processes are still alive. The system process kills them
// and exits with the error, which must become the exit code of the program.

main:
  4.repeat:
    spawn:: sleep --ms=10_000
  spawn::
    sleep --ms=10
    throw "UNCAUGHT"
  sleep --ms=10_000
