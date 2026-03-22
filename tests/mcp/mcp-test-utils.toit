// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import encoding.json
import io

import ...tools.mcp.server show McpServer

/** Encodes the given $msg as a Content-Length framed message. */
frame-message msg/Map -> ByteArray:
  payload := json.encode msg
  header := "Content-Length: $(payload.size)\r\n\r\n"
  buffer := io.Buffer
  buffer.write header
  buffer.write payload
  return buffer.bytes

/** Reads a single Content-Length framed response from the given $reader. */
read-response reader/io.Reader -> Map:
  content-length := -1
  while true:
    line := reader.read-line
    if line == null: throw "Unexpected end of input"
    if line == "":
      // End of headers.
      break
    if line.starts-with "Content-Length:":
      content-length = int.parse (line.trim --left "Content-Length:").trim
    else:
      throw "Unexpected header: $line"
  if content-length == -1: throw "Missing Content-Length header"
  payload := reader.read-bytes content-length
  return json.decode payload

/** Builds a JSON-RPC initialize request with the given $id. */
build-initialize-request --id/int=1 -> Map:
  return {
    "jsonrpc": "2.0",
    "id": id,
    "method": "initialize",
    "params": {
      "protocolVersion": "2025-03-26",
      "capabilities": {:},
      "clientInfo": {"name": "test", "version": "1.0"},
    },
  }

/** Builds a JSON-RPC initialized notification. */
build-initialized-notification -> Map:
  return {
    "jsonrpc": "2.0",
    "method": "notifications/initialized",
  }

/**
Creates an McpServer with the given input bytes and returns the server
  and the output buffer.
The $tools and $tool-handlers are passed through to the server constructor.
*/
create-server input-bytes/ByteArray --tools/List=[] --tool-handlers/Map={:} -> List:
  reader := io.Reader input-bytes
  output := io.Buffer
  server := McpServer
      --reader=reader
      --writer=output
      --tools=tools
      --tool-handlers=tool-handlers
  return [server, output]
