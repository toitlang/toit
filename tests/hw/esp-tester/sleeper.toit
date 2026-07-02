// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
A tiny keep-alive container for the EC618 mini-jag test rig.

The EC618 envelope installs this alongside the mini-jag agent (see the tester's
envelope build). It does nothing but stay alive in its own container, so the VM
always has a runnable process and never reaches EXIT_DONE / deep-sleep-without-
wakeup — which on a no-remote-reset rig would gate the watchdog and brick the
board (see docs/ec618-hw-tests.md). Being a separate container, it survives a
crash of the agent, so the watchdog (fed only by host messages in mini-jag.toit)
can then reset the device back into a fresh agent. It deliberately never touches
the watchdog or any shared service.
*/

main:
  while true:
    sleep --ms=1000
