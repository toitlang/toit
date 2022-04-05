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

import services.arguments show ArgumentParser
import host.file
import monitor
import host.pipe
import reader show BufferedReader

import .utils
import .rpc
import .server
import .uri_path_translator


// Request id must be global, as lambdas only capture the current value of a variable.
current_request_id := -1

log_packet --to_server=false packet:
  prefix := to_server ? "-> " : "<- "
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
  parser := ArgumentParser
  parser.add_flag "print-out"
  parser.add_flag "use-std-ports"
  parser.add_flag "log-formatted"
  parsed := parser.parse args

  use_std_ports := parsed["use-std-ports"]
  log_formatted := parsed["log-formatted"]
  if use_std_ports and log_formatted:
    print "Can't use std ports and log formatted at same time"
    exit 1

  server_to   := null
  server_from := null
  if use_std_ports:
    server_from = pipe.stdin
    server_to   = pipe.stdout
  else:
    server_from = FakePipe
    server_to   = FakePipe
    server_rpc_connection := RpcConnection (BufferedReader server_to) server_from
    server := LspServer --no-use_rpc_filesystem server_rpc_connection null UriPathTranslator
    task:: catch --trace: server.run

  debug_file := parsed.rest[0]
  replay_rpc := RpcConnection (BufferedReader (file.Stream.for_read debug_file)) pipe.stderr
  std_rpc := RpcConnection (BufferedReader server_from) server_to

  channel := monitor.Channel 1

  task:: catch --trace:
    while true:
      packet := replay_rpc.read_packet
      if packet == null: break
      if packet.contains "result" and packet.contains "id":
        // Don't send responses before they have been requested.
        while packet["id"] > current_request_id:
          channel.receive
      if parsed["print-out"]:
        if log_formatted:
          log_packet --to_server packet
        else:
          replay_rpc.write_packet packet
      std_rpc.write_packet packet
      sleep --ms=100

  task:: catch --trace:
    while true:
      packet := std_rpc.read_packet
      if log_formatted:
        log_packet packet
      else:
        replay_rpc.write_packet packet
      if packet.contains "result": continue
      // If it contains an id, but isn't a result, it's a request.
      packet.get "id" --if_present=:
        current_request_id = it
        channel.send it
