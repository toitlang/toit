// Copyright (C) 2019 Toitware ApS.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

import host.pipe
import host.file
import io
import monitor

/**
Starts piping all data from $from to $to while logging
  all transferred data in log_stream, using the given mutex to make
  sure that the log stream is consistent.
*/
start-piping from/io.Reader to/io.Writer --log-writer/io.Writer --mutex -> none:
  task::
    catch --trace:
      while true:
        chunk := from.read
        if not chunk: break
        to.write chunk
        mutex.do:
          log-writer.write chunk


/**
Use this executable instead of the original server.toit server.

All communications through stdin/stdout are logged to the `LOG` file.
This makes it possible to detect spurious output that interferes with
  the communication between the LSP client and server. (It really should
  have been a communication based on ports...).
*/
main args:
  TOIT-RUN := "toit.run"
  SERVER := "tools/lsp/server/server.toit"
  LOG := "/tmp/lsp_logs"

  process := pipe.fork
      --use-path
      --create-stdin
      --create-stdout
      TOIT-RUN
      [
        TOIT-RUN,
        SERVER
      ]

  mutex := monitor.Mutex
  log-file := file.Stream.for-write LOG

  start-piping pipe.stdin.in process.stdin.out --log-writer=log-file.out --mutex=mutex
  start-piping process.stdout.in pipe.stdout.out --log-writer=log-file.out --mutex=mutex

  exit-value := process.wait
  exit-code := pipe.exit-code exit-value
  exit-signal := pipe.exit-signal exit-value
  if exit-signal:
    throw "$TOIT-RUN exited with signal $exit-signal"
  if exit-code != 0:
    throw "$TOIT-RUN exited with code $exit-code"
