// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
import gpio

// Diagnose the unverified RX wire using only weak input pulls. Observe RUN
// as well so an accidental connection between the two wires is visible.
main:
  pin := gpio.Pin 4 --input
  run := gpio.Pin 21 --input
  try:
    [false, true, false, true].do: |up/bool|
      pin.configure --input --pull-up=up --pull-down=(not up)
      12.repeat:
        print "RX-PULL $(up ? 1 : 0) $(pin.get) RUN $(run.get)"
        sleep --ms=250
  finally:
    pin.close
    run.close
