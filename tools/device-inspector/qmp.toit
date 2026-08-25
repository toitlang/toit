// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import encoding.json
import io

class Client:
  reader_/io.Reader
  writer_/io.Writer
  next-id_/int := 1

  constructor .reader_ .writer_:
    greeting := read-message_
    if not greeting.contains "QMP": throw "INVALID_QMP_GREETING"
    execute "qmp_capabilities"

  execute command/string arguments/Map?=null -> any:
    id := next-id_++
    request := {"execute": command, "id": id}
    if arguments: request["arguments"] = arguments
    writer_.write ((json.encode request) + #[10]) --flush
    while true:
      response := read-message_
      if (response.get "id") != id: continue
      if response.contains "error":
        throw "QMP_COMMAND_FAILED: $command: $(response["error"])"
      return response.get "return"

  quit -> none:
    // QEMU may close the transport before the quit response is observed.
    request := {"execute": "quit", "id": next-id_++}
    writer_.write ((json.encode request) + #[10]) --flush

  read-message_ -> Map:
    line := reader_.read-line
    if not line: throw "QMP_CONNECTION_CLOSED"
    result := json.decode line.to-byte-array
    if not result is Map: throw "INVALID_QMP_MESSAGE"
    return result
