// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ec618
import ec618.slot
import expect show *

// This suite is for the manually booted dev board, not the relay-powered
// UART1 module. Do not validate an OTA trial as a side effect of testing.
main args:
  expect-equals 0 ec618.console-uart-id
  expect (not slot.trial)
  expect slot.SLOT-SIZE > 0
  base := ec618.base-id
  if not args.is-empty and args[0] != "": expect-equals args[0] base
  print "EC618 RIG READY base=$base slot=$(string.from-rune slot.active) console=uart0 trial=false"
