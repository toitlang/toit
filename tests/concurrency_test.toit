// Copyright (C) 2018 Toitware ApS. All rights reserved.

import monitor

main:
  sem := monitor.Semaphore
  task:: (5.repeat: sem.down); print "Done down!"
  task:: (5.repeat: sem.up); print "Done up!"

  ch := monitor.Channel 8
  task:: 17.repeat: print ch.receive
  task:: 17.repeat: ch.send it
