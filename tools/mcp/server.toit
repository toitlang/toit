// Copyright (C) 2026 Toitware ApS.
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

import encoding.json as json
import io

/**
An MCP (Model Context Protocol) server that communicates over JSON-RPC 2.0
  with Content-Length framing.
*/
class McpServer:
  reader_ /io.Reader
  writer_ /io.Writer
  tools_ /List
  tool-handlers_ /Map

  /**
  Creates an MCP server.

  The $tools list contains tool definition maps, each with "name",
    "description", and "inputSchema" entries.
  The $tool-handlers map maps tool names to handler lambdas. Each handler
    receives an arguments $Map and returns a string (the text result).
  */
  constructor --reader/io.Reader --writer/io.Writer --tools/List --tool-handlers/Map:
    reader_ = reader
    writer_ = writer
    tools_ = tools
    tool-handlers_ = tool-handlers

  /**
  Starts the server loop.

  Blocks until shutdown or EOF.
  */
  run -> none:
    while true:
      message := read-message_
      if not message: return

      method := message.get "method"
      id := message.get "id"

      // Notifications have no id -- don't respond.
      if not id: continue

      if method == "shutdown":
        reply_ id {:}
        return

      result := dispatch_ method (message.get "params")
      if result is Error_:
        error := result as Error_
        reply-error_ id error.code error.message
      else:
        reply_ id result

  /**
  Reads a Content-Length framed JSON-RPC message.

  Returns null on EOF.
  */
  read-message_ -> Map?:
    line := reader_.read-line
    if line == null or line == "": return null
    payload-len := -1
    while line != "":
      if line == null: return null
      if line.starts-with "Content-Length:":
        payload-len = int.parse (line.trim --left "Content-Length:").trim
      line = reader_.read-line
    if payload-len == -1: return null
    encoded := reader_.read-bytes payload-len
    return json.decode encoded

  /**
  Writes a JSON-RPC success response with the given $id and $result.
  */
  reply_ id/any result/any -> none:
    write-message_ {
      "jsonrpc": "2.0",
      "id": id,
      "result": result,
    }

  /**
  Writes a JSON-RPC error response with the given $id, error $code,
    and $message.
  */
  reply-error_ id/any code/int message/string -> none:
    write-message_ {
      "jsonrpc": "2.0",
      "id": id,
      "error": {
        "code": code,
        "message": message,
      },
    }

  /**
  Writes a Content-Length framed JSON message.
  */
  write-message_ payload/Map -> none:
    encoded := json.encode payload
    writeln_ "Content-Length: $(encoded.size)"
    writeln_ ""
    writer_.write encoded

  /**
  Dispatches a method call and returns the result.

  Returns an $Error_ for unknown methods.
  */
  dispatch_ method/string? params/any -> any:
    if method == "initialize":
      return {
        "protocolVersion": "2025-03-26",
        "capabilities": {"tools": {:}},
        "serverInfo": {"name": "toit-mcp", "version": "1.0.0"},
      }
    if method == "tools/list":
      return {
        "tools": tools_,
      }
    if method == "tools/call":
      return dispatch-tool-call_ params
    if method == "shutdown":
      return {:}
    return Error_ -32601 "Method not found: $method"

  /**
  Dispatches a tools/call request.

  Looks up the tool handler by name and calls it with the provided
    arguments. Returns an error result if the tool is not found.
  */
  dispatch-tool-call_ params/Map -> Map:
    name := params["name"]
    arguments := params.get "arguments" --if-absent=: {:}
    handler := tool-handlers_.get name
    if not handler:
      return {
        "content": [{"type": "text", "text": "Unknown tool: $name"}],
        "isError": true,
      }
    result := handler.call arguments
    return {
      "content": [{"type": "text", "text": result}],
    }

  /**
  Writes a line followed by `\r\n` to the writer.
  */
  writeln_ line/string -> none:
    writer_.write line.to-byte-array
    crlf := ByteArray 2
    crlf[0] = '\r'
    crlf[1] = '\n'
    writer_.write crlf

/**
Internal error representation for JSON-RPC errors.
*/
class Error_:
  code /int
  message /string

  constructor .code .message:
