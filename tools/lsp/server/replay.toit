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

import cli
import host.file
import monitor
import host.pipe
import reader show BufferedReader

import .utils
import .rpc
import .server
import .uri-path-translator


// Request id must be global, as lambdas only capture the current value of a variable.
current-request-id := -1

log-packet --to-server=false packet:
  prefix := to-server ? "-> " : "<- "
  if packet.contains "result":
    print "$prefix $packet["id"] $packet["result"]\n"
  else if packet.contains "id":
    print "$prefix $packet["method"] $packet["id"] $packet["params"]\n"
  else:
    print "$prefix $packet["method"] $packet["params"]\n"

/**
Replays a given debug-output (created with the debug-option in the VSCode extension).
Can either use stdin/stdout to communicate with the server, or just create a
  fake pipe.

Use:
  With fake-pipe:
  ```
  toit tools/lsp/server/replay.toit --log-formatted /tmp/debug_client_to_server-*.log
  ```
  ``` sh
  mkfifo fifo0 fifo1
  toit tools/lsp/server/server.toit > fifo1 < fifo0 &
  toit tools/lsp/server/replay.toit /tmp/debug_client_to_server-*.log < fifo1 > fifo0
  ```
*/
main args:
  parsed := null
  parser := cli.Command "replay"
      --rest=[
          cli.OptionString "debug-file" --required
      ]
      --options=[
          cli.Flag "print-out" --default=false,
          cli.Flag "use-std-ports" --default=false,
          cli.Flag "log-formatted" --default=false,
      ]
      --run=:: parsed = it
  parser.run args
  if not parsed: exit 0

  use-std-ports := parsed["use-std-ports"]
  log-formatted := parsed["log-formatted"]
  if use-std-ports and log-formatted:
    print "Can't use std ports and log formatted at same time"
    exit 1

  server-to   := null
  server-from := null
  if use-std-ports:
    server-from = pipe.stdin
    server-to   = pipe.stdout
  else:
    server-from = FakePipe
    server-to   = FakePipe
    server-rpc-connection := RpcConnection (BufferedReader server-to) server-from
    server := LspServer server-rpc-connection null UriPathTranslator
    task:: catch --trace: server.run

  debug-file := parsed["debug-file"]
  replay-rpc := RpcConnection (BufferedReader (file.Stream.for-read debug-file)) pipe.stderr
  std-rpc := RpcConnection (BufferedReader server-from) server-to

  channel := monitor.Channel 1

  task:: catch --trace:
    while true:
      packet := replay-rpc.read-packet
      if packet == null: break
      if packet.contains "result" and packet.contains "id":
        // Don't send responses before they have been requested.
        while packet["id"] > current-request-id:
          channel.receive
      if parsed["print-out"]:
        if log-formatted:
          log-packet --to-server packet
        else:
          replay-rpc.write-packet packet
      std-rpc.write-packet packet
      sleep --ms=100

  task:: catch --trace:
    while true:
      packet := std-rpc.read-packet
      if log-formatted:
        log-packet packet
      else:
        replay-rpc.write-packet packet
      if packet.contains "result": continue
      // If it contains an id, but isn't a result, it's a request.
      packet.get "id" --if-present=:
        current-request-id = it
        channel.send it
