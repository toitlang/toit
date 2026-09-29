// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

// Tasks and timers are scheduled on the JavaScript event loop. The page
// stays responsive while they run.

import monitor

main:
  channel := monitor.Channel 10
  producers := List 3: | id |
    task::
      5.repeat: | i |
        sleep --ms=(100 + id * 70)
        channel.send "producer $id: message $i"
  15.repeat:
    print channel.receive
  print "All messages received."
