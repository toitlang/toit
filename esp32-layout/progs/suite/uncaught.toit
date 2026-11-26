// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

// The device version of tests/spawn-uncaught-exit-code-input.toit, installed
// as a critical boot container: a spawned process dies with an uncaught
// exception while the main process and four other spawned processes are
// alive. The container fails, the system process kills the others and exits
// with the error, so the VM must take the error path ("entering deep sleep
// for 1s due to error"), never "deep sleep without wakeup time". After the
// 1 s sleep the board boots and runs it again.

main:
  print "UNCAUGHT start"
  4.repeat:
    spawn:: sleep --ms=10_000
  spawn::
    sleep --ms=10
    throw "UNCAUGHT"
  sleep --ms=10_000
