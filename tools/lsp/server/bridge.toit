// Copyright (C) 2019 Toitware ApS. All rights reserved.

import host.pipe
import writer
import host.file
import monitor

/**
Starts piping all data from [from_stream] to [to_stream] while logging
  all transferred data in log_stream, using the given mutex to make
  sure that the log stream is consistent.
*/
start_piping from_stream to_stream --log_stream --mutex -> none:
  task::
    catch --trace:
      to_writer := writer.Writer to_stream
      log_writer := writer.Writer log_stream
      while true:
        chunk := from_stream.read
        if not chunk: break
        to_writer.write chunk
        mutex.do:
          log_writer.write chunk


/**
Use this executable instead of the original server.toit server.

All communications through stdin/stdout are logged to the `LOG` file.
This makes it possible to detect spurious output that interferes with
  the communication between the LSP client and server. (It really should
  have been a communication based on ports...).
*/
main args:
  TOITC := "/home/flo/code/toit_lsp/build/debug/sdk/bin/toitc"
  SERVER := "/home/flo/code/toit_lsp/tools/lsp/server/server.toit"
  LOG := "/tmp/lsp_logs"

  pipes := pipe.fork
    true
    pipe.PIPE_CREATED  // stdin
    pipe.PIPE_CREATED  // stdout
    pipe.PIPE_INHERITED  // stderr
    TOITC
    [
      TOITC,
      SERVER
    ]
  pipe_to := pipes[0]
  pipe_from := pipes[1]
  pid := pipes[3]

  mutex := monitor.Mutex
  log_file := file.Stream.for_write LOG

  start_piping pipe.stdin pipe_to --log_stream=log_file --mutex=mutex
  start_piping pipe_from pipe.stdout --log_stream=log_file --mutex=mutex

  exit (pipe.wait_for pid)
