// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import monitor

main:
  sem := monitor.Semaphore
  task:: (5.repeat: sem.down); print "Done down!"
  task:: (5.repeat: sem.up); print "Done up!"

  ch := monitor.Channel 8
  task:: 17.repeat: print ch.receive
  task:: 17.repeat: ch.send it
