// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import io
import encoding.json

import ...tools.mcp.server show McpServer

main:
  test-initialize
  test-tools-list
  test-tools-call
  test-unknown-tool
  test-notification-no-response
  test-multiple-tools

/// Encodes the given $msg as a Content-Length framed message.
frame-message msg/Map -> ByteArray:
  payload := json.encode msg
  header := "Content-Length: $(payload.size)\r\n\r\n"
  buffer := io.Buffer
  buffer.write header
  buffer.write payload
  return buffer.bytes

/// Reads a single Content-Length framed response from the given $reader.
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

/// Builds a JSON-RPC initialize request with the given $id.
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

/// Builds a JSON-RPC initialized notification.
build-initialized-notification -> Map:
  return {
    "jsonrpc": "2.0",
    "method": "notifications/initialized",
  }

/// Creates an McpServer with the given input bytes and returns the server
///   and the output buffer.
/// The $tools and $tool-handlers are passed through to the server constructor.
create-server input-bytes/ByteArray --tools/List=[] --tool-handlers/Map={:} -> List:
  reader := io.Reader input-bytes
  output := io.Buffer
  server := McpServer
      --reader=reader
      --writer=output
      --tools=tools
      --tool-handlers=tool-handlers
  return [server, output]

test-initialize:
  input := io.Buffer
  input.write (frame-message (build-initialize-request))
  input.write (frame-message (build-initialized-notification))

  result := create-server input.bytes
  server := result[0] as McpServer
  output := result[1] as io.Buffer

  server.run

  response := read-response (io.Reader output.bytes)
  expect-equals "2.0" response["jsonrpc"]
  expect-equals 1 response["id"]
  result-map := response["result"] as Map
  expect-equals "2025-03-26" result-map["protocolVersion"]

  server-info := result-map["serverInfo"] as Map
  expect-equals "toit-mcp" server-info["name"]

  capabilities := result-map["capabilities"] as Map
  expect (capabilities.contains "tools")

test-tools-list:
  tools := [
    {
      "name": "greet",
      "description": "Greets the user",
      "inputSchema": {
        "type": "object",
        "properties": {
          "name": {"type": "string"},
        },
      },
    },
  ]

  input := io.Buffer
  input.write (frame-message (build-initialize-request --id=1))
  input.write (frame-message (build-initialized-notification))
  input.write (frame-message {
    "jsonrpc": "2.0",
    "id": 2,
    "method": "tools/list",
  })

  result := create-server input.bytes --tools=tools --tool-handlers={
    "greet": :: | args/Map | "hello $(args["name"])",
  }
  server := result[0] as McpServer
  output := result[1] as io.Buffer

  server.run

  reader := io.Reader output.bytes
  // Skip the initialize response.
  read-response reader

  response := read-response reader
  expect-equals "2.0" response["jsonrpc"]
  expect-equals 2 response["id"]
  result-map := response["result"] as Map
  result-tools := result-map["tools"] as List
  expect-equals 1 result-tools.size
  tool := result-tools[0] as Map
  expect-equals "greet" tool["name"]
  expect-equals "Greets the user" tool["description"]

test-tools-call:
  tools := [
    {
      "name": "hello",
      "description": "Says hello",
      "inputSchema": {
        "type": "object",
        "properties": {:},
      },
    },
  ]

  input := io.Buffer
  input.write (frame-message (build-initialize-request --id=1))
  input.write (frame-message (build-initialized-notification))
  input.write (frame-message {
    "jsonrpc": "2.0",
    "id": 2,
    "method": "tools/call",
    "params": {
      "name": "hello",
      "arguments": {:},
    },
  })

  result := create-server input.bytes --tools=tools --tool-handlers={
    "hello": :: | args/Map | "hello world",
  }
  server := result[0] as McpServer
  output := result[1] as io.Buffer

  server.run

  reader := io.Reader output.bytes
  // Skip the initialize response.
  read-response reader

  response := read-response reader
  expect-equals "2.0" response["jsonrpc"]
  expect-equals 2 response["id"]
  result-map := response["result"] as Map
  content := result-map["content"] as List
  expect-equals 1 content.size
  item := content[0] as Map
  expect-equals "text" item["type"]
  expect-equals "hello world" item["text"]

test-unknown-tool:
  input := io.Buffer
  input.write (frame-message (build-initialize-request --id=1))
  input.write (frame-message (build-initialized-notification))
  input.write (frame-message {
    "jsonrpc": "2.0",
    "id": 2,
    "method": "tools/call",
    "params": {
      "name": "nonexistent",
      "arguments": {:},
    },
  })

  result := create-server input.bytes
  server := result[0] as McpServer
  output := result[1] as io.Buffer

  server.run

  reader := io.Reader output.bytes
  // Skip the initialize response.
  read-response reader

  response := read-response reader
  expect-equals "2.0" response["jsonrpc"]
  expect-equals 2 response["id"]
  result-map := response["result"] as Map
  expect-equals true result-map["isError"]

test-notification-no-response:
  input := io.Buffer
  input.write (frame-message (build-initialize-request --id=1))
  // The initialized notification should not produce a response.
  input.write (frame-message (build-initialized-notification))
  // Send a tools/list request to verify we can still get a response
  // after the notification (proving the notification didn't produce one).
  input.write (frame-message {
    "jsonrpc": "2.0",
    "id": 3,
    "method": "tools/list",
  })

  result := create-server input.bytes
  server := result[0] as McpServer
  output := result[1] as io.Buffer

  server.run

  reader := io.Reader output.bytes
  // First response is for initialize (id=1).
  response1 := read-response reader
  expect-equals 1 response1["id"]

  // The next response should be for tools/list (id=3), not for the
  // notification. This proves the notification didn't produce a response.
  response2 := read-response reader
  expect-equals 3 response2["id"]

test-multiple-tools:
  tools := [
    {
      "name": "add",
      "description": "Adds two numbers",
      "inputSchema": {
        "type": "object",
        "properties": {
          "a": {"type": "number"},
          "b": {"type": "number"},
        },
      },
    },
    {
      "name": "upper",
      "description": "Converts to uppercase",
      "inputSchema": {
        "type": "object",
        "properties": {
          "text": {"type": "string"},
        },
      },
    },
  ]
  tool-handlers := {
    "add": :: | args/Map |
      a := args["a"] as int
      b := args["b"] as int
      "$(a + b)",
    "upper": :: | args/Map |
      text := args["text"] as string
      text.to-ascii-upper,
  }

  input := io.Buffer
  input.write (frame-message (build-initialize-request --id=1))
  input.write (frame-message (build-initialized-notification))
  input.write (frame-message {
    "jsonrpc": "2.0",
    "id": 2,
    "method": "tools/call",
    "params": {
      "name": "add",
      "arguments": {"a": 3, "b": 4},
    },
  })
  input.write (frame-message {
    "jsonrpc": "2.0",
    "id": 3,
    "method": "tools/call",
    "params": {
      "name": "upper",
      "arguments": {"text": "hello"},
    },
  })

  result := create-server input.bytes --tools=tools --tool-handlers=tool-handlers
  server := result[0] as McpServer
  output := result[1] as io.Buffer

  server.run

  reader := io.Reader output.bytes
  // Skip the initialize response.
  read-response reader

  response-add := read-response reader
  expect-equals 2 response-add["id"]
  result-add := response-add["result"] as Map
  content-add := result-add["content"] as List
  expect-equals "7" ((content-add[0] as Map)["text"])

  response-upper := read-response reader
  expect-equals 3 response-upper["id"]
  result-upper := response-upper["result"] as Map
  content-upper := result-upper["content"] as List
  expect-equals "HELLO" ((content-upper[0] as Map)["text"])
