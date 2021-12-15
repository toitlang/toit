// Copyright (C) 2019 Toitware ApS. All rights reserved.

import server.tar as server
import ..tools.pipe as pipe
import reader show BufferedReader
import monitor
import expect show *

class Stress:
  executable ::= ?

  constructor .executable:

  run_compiler id channel:
    channel.send "$id: started"
    pipes := pipe.fork
        true                // use_path
        pipe.PIPE_CREATED   // stdin
        pipe.PIPE_CREATED   // stdout
        pipe.PIPE_INHERITED // stderr
        executable
        [
          executable,
        ]
    to   := pipes[0]
    from := pipes[1]
    pid  := pipes[3]
    pipe.dont_wait_for pid
    channel.send "$id: forked"

    // Stress pipes.
    LINES_COUNT ::= 500
    for i := 0; i < LINES_COUNT; i++:
      to.write "line$i\n"
    to.close

    reader := BufferedReader from
    read_counter := 0
    while true:
      line := reader.read_line
      if line == null:
        channel.send "$id: done"
        break
      expect_equals "line$read_counter" line
      read_counter++
    expect_equals LINES_COUNT read_counter
    from.close
    channel.send null

logs := []

main:
  stress := Stress "/bin/cat"

  now_us := Time.monotonic_us
  counter := 0
  while Time.monotonic_us - now_us < 15_000_000:
    print "Iteration $(counter++)"
    logs.clear
    channel := monitor.Channel 100
    running := 0
    for i := 0; i < 30; i++:
      running++
      task:: stress.run_compiler i channel
    while true:
      value := channel.receive
      if value == null:
        running--
        if running == 0: break
      else:
        // log value
        logs.add value
  print "time's up"
