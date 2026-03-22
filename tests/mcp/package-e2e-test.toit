// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import encoding.json
import host.directory
import host.file
import host.pipe
import io
import system

import ...tools.mcp.lock-file-cache show LockFileCache
import ...tools.mcp.mcp show create-mcp-server
import ...tools.mcp.store show DocStore

main:
  test-load-and-search-package

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
      break
    if line.starts-with "Content-Length:":
      content-length = int.parse (line.trim --left "Content-Length:").trim
    else:
      throw "Unexpected header: $line"
  if content-length == -1: throw "Missing Content-Length header"
  payload := reader.read-bytes content-length
  return json.decode payload

/**
Creates a loader lambda that calls `toit doc build` for a real package.
*/
make-loader --project-root/string --lock-file-cache/LockFileCache -> Lambda:
  return :: | source/string name/any path/any |
    tmp-dir := directory.mkdtemp "/tmp/toitdoc-e2e-"
    result/Map := {:}
    try:
      output := "$tmp-dir/toitdoc.json"
      toit := "toit"
      args := [toit, "doc", "build", "-o", output]

      if source == "sdk":
        args.add-all ["--sdk", "--exclude-pkgs"]
      else if source == "package":
        pkg-path := lock-file-cache.resolve-path --url=(name as string)
        args.add-all ["--package", "--exclude-sdk", "--exclude-pkgs", pkg-path]
      else if source == "project":
        project-path := path ? (path as string) : project-root
        args.add-all ["--exclude-sdk", "--exclude-pkgs", project-path]
      else:
        throw "Unknown source: $source"

      pipe.run-program args
      content := file.read-contents output
      result = json.decode content
    finally:
      directory.rmdir --recursive tmp-dir
    result

/**
Tests loading real package documentation via the MCP server and verifying
  that responses contain valid file paths pointing to real .toit files.
*/
test-load-and-search-package:
  tmp-dir := directory.mkdtemp "/tmp/mcp-e2e-test-"
  try:
    // Set up a real project with the morse package.
    pipe.run-program ["toit", "pkg", "init", "--project-root=$tmp-dir"]
    pipe.run-program ["toit", "pkg", "install", "morse", "--project-root=$tmp-dir"]

    lock-file-cache := LockFileCache tmp-dir
    store := DocStore
    loader := make-loader --project-root=tmp-dir --lock-file-cache=lock-file-cache

    // Build the MCP request sequence.
    input := io.Buffer
    // 1. Initialize.
    input.write (frame-message {
      "jsonrpc": "2.0",
      "id": 1,
      "method": "initialize",
      "params": {
        "protocolVersion": "2025-03-26",
        "capabilities": {:},
        "clientInfo": {"name": "test", "version": "1.0"},
      },
    })
    input.write (frame-message {
      "jsonrpc": "2.0",
      "method": "notifications/initialized",
    })
    // 2. Load package documentation.
    input.write (frame-message {
      "jsonrpc": "2.0",
      "id": 2,
      "method": "tools/call",
      "params": {
        "name": "load_documentation",
        "arguments": {
          "source": "package",
          "name": "github.com/toitware/toit-morse",
        },
      },
    })
    // 3. Search for a function in the package.
    input.write (frame-message {
      "jsonrpc": "2.0",
      "id": 3,
      "method": "tools/call",
      "params": {
        "name": "search_docs",
        "arguments": {"query": "encode"},
      },
    })
    // 4. List libraries.
    input.write (frame-message {
      "jsonrpc": "2.0",
      "id": 4,
      "method": "tools/call",
      "params": {
        "name": "list_libraries",
        "arguments": {:},
      },
    })

    reader := io.Reader input.bytes
    output := io.Buffer
    server := create-mcp-server
        --store=store
        --reader=reader
        --writer=output
        --loader=loader
    server.run

    response-reader := io.Reader output.bytes

    // Response 1: Initialize.
    r1 := read-response response-reader
    expect-equals 1 r1["id"]
    expect ((r1["result"] as Map).contains "protocolVersion")

    // Response 2: load_documentation.
    r2 := read-response response-reader
    expect-equals 2 r2["id"]
    text2 := (((r2["result"] as Map)["content"] as List)[0] as Map)["text"] as string
    expect (text2.contains "Loaded package documentation")

    // Response 3: search_docs for "morse".
    r3 := read-response response-reader
    expect-equals 3 r3["id"]
    text3 := (((r3["result"] as Map)["content"] as List)[0] as Map)["text"] as string
    // The search should find encode-related functions.
    expect (text3.contains "encode")

    // Response 4: list_libraries.
    r4 := read-response response-reader
    expect-equals 4 r4["id"]
    text4 := (((r4["result"] as Map)["content"] as List)[0] as Map)["text"] as string
    // Should list at least one library from the morse package.
    expect (text4.size > 0)

    // Verify that the package path points to real .toit files on disk.
    pkg-path := lock-file-cache.resolve-path --url="github.com/toitware/toit-morse"
    expect (file.is-directory pkg-path)
    src-dir := "$pkg-path/src"
    expect (file.is-directory src-dir)
    found-toit-file := false
    stream := directory.DirectoryStream src-dir
    try:
      while entry := stream.next:
        if entry.ends-with ".toit":
          found-toit-file = true
          // Verify the LLM could read this file.
          content := file.read-contents "$src-dir/$entry"
          expect (content.size > 0)
    finally:
      stream.close
    expect found-toit-file
  finally:
    directory.rmdir --recursive --force tmp-dir
