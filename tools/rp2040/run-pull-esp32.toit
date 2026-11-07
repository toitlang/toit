// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
import gpio

// First check RUN with weak input pulls. No output driver is enabled.
main:
  run := gpio.Pin 21 --input --pull-up
  try:
    print "RUN-PULL UP $(run.get)"
    sleep --ms=1500
    run.configure --input --pull-down
    12.repeat:
      print "RUN-PULL DOWN $(run.get)"
      sleep --ms=250
    run.configure --input
    print "RUN-PULL RELEASE $(run.get)"
  finally:
    run.close
