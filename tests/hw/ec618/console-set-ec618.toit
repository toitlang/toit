// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

/**
Sets the console byte in the anchor record (rig utility, not a test).

The target UART id comes in as the test argument; run it via the tester:

  tester.toit run ... --arg 1 tests/hw/ec618/console-set-ec618.toit

The change takes effect at the NEXT boot: the running agent keeps its
current control UART, and on a rig the mini-jag general watchdog reboots
the device ~60 s after the host goes quiet — so simply stop talking and
the new console comes up on its own. The way back is the same helper via
whichever lane still reaches the agent (worst case the UART2 rescue lane,
which arms 45 s into any un-contacted boot when the console is not 2).
*/

import ec618

main args:
  target := int.parse args[0]
  before := ec618.print-uart-id
  ec618.set-console-uart target
  print "console-set: anchor console byte $before -> $target (takes effect at next boot)"
