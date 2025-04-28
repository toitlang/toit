// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import host.pipe
import monitor
import net
import net.tcp
import .exit-codes
import .boot-kill-source show TEST-PORT-ENV TEST-INTERVAL-MS
import .util show EnvelopeTest with-test

/**
Test that we can kill the boot script and that it kills the nested Toit program
*/

main args:
  network := net.open

  started-latch := monitor.Latch
  stopped-latch := monitor.Latch
  server := network.tcp-listen 0
  task::
    connection := server.accept
    while true:
      chunk := null
      with-timeout --ms=(5 * TEST-INTERVAL-MS):
        chunk = connection.in.read
      if not chunk:
        stopped-latch.set true
        break
      if not started-latch.has-value: started-latch.set true
    connection.close

  with-test args: | test/EnvelopeTest |
    test.install --name="deep-sleep" --source-path="./boot-kill-source.toit"
    test.extract-to-dir --dir-path=test.tmp-dir

    env := { TEST-PORT-ENV: "$server.local-address.port" }
    test.boot_ test.tmp-dir --env=env: | args env |
      fork-data := pipe.fork
          --environment=env
          true    // use_path
          pipe.PIPE-INHERITED
          pipe.PIPE-INHERITED
          pipe.PIPE-INHERITED
          args[0]
          args
      child-process := fork-data[3]

      // Wait for the client to start sending.
      started-latch.get

      // Kill it.
      SIGTERM ::= 15
      pipe.kill_ child-process SIGTERM

      pipe.wait-for child-process

      with-timeout --ms=3_000:
        // Wait for the client to stop.
        stopped-latch.get

      print "test done"
