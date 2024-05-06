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
Starts piping all data from [from_stream] to [to_stream] while logging
  all transferred data in log_stream, using the given mutex to make
  sure that the log stream is consistent.
*/
start-piping from-stream to-stream --log-stream --mutex -> none:
  task::
    catch --trace:
      to-writer := io.Writer.adapt to-stream
      log-writer := io.Writer.adapt log-stream
      while true:
        chunk := from-stream.read
        if not chunk: break
        to-writer.write chunk
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

  pipes := pipe.fork
    true
    pipe.PIPE-CREATED  // stdin
    pipe.PIPE-CREATED  // stdout
    pipe.PIPE-INHERITED  // stderr
    TOIT-RUN
    [
      TOIT-RUN,
      SERVER
    ]
  pipe-to := pipes[0]
  pipe-from := pipes[1]
  pid := pipes[3]

  mutex := monitor.Mutex
  log-file := file.Stream.for-write LOG

  start-piping pipe.stdin pipe-to --log-stream=log-file --mutex=mutex
  start-piping pipe-from pipe.stdout --log-stream=log-file --mutex=mutex

  exit-value := pipe.wait-for pid
  exit-code := pipe.exit-code exit-value
  exit-signal := pipe.exit-signal exit-value
  if exit-signal:
    throw "$TOIT-RUN exited with signal $exit-signal"
  if exit-code != 0:
    throw "$TOIT-RUN exited with code $exit-code"
