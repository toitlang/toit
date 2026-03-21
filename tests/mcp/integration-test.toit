// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import io
import encoding.json

import ...tools.mcp.mcp show create-mcp-server
import ...tools.mcp.store show DocStore
import ...tools.toitdoc.src.builder show
    Class
    ClassStructure
    Doc
    Library
    Module
    Toitdoc
    DocParagraph
    DocSection
    DocText

main:
  test-full-session
  test-scoped-search
  test-list-sources
  test-unknown-tool-integration
  test-search-no-results-integration

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
      break
    if line.starts-with "Content-Length:":
      content-length = int.parse (line.trim --left "Content-Length:").trim
    else:
      throw "Unexpected header: $line"
  if content-length == -1: throw "Missing Content-Length header"
  payload := reader.read-bytes content-length
  return json.decode payload

/** Creates a toitdoc with a single text paragraph. */
make-toitdoc text/string -> Toitdoc:
  return Toitdoc --sections=[
    DocSection --title=null --level=0 --statements=[
      DocParagraph --expressions=[DocText --text=text],
    ],
  ]

/** Creates a simple class with the given $name and $toitdoc-text. */
make-class name/string toitdoc-text/string -> Class:
  return Class
      --name=name
      --kind="class"
      --is-abstract=false
      --is-private=false
      --exported-from=null
      --interfaces=[]
      --mixins=[]
      --extends=null
      --structure=(ClassStructure
          --statics=[]
          --constructors=[]
          --factories=[]
          --fields=[]
          --methods=[])
      --toitdoc=(make-toitdoc toitdoc-text)

/** Creates a simple module with the given $name and $classes. */
make-module name/string --classes/List=[] -> Module:
  return Module
      --name=name
      --is-private=false
      --classes=classes
      --interfaces=[]
      --mixins=[]
      --export-classes=[]
      --export-interfaces=[]
      --export-mixins=[]
      --functions=[]
      --export-functions=[]
      --globals=[]
      --export-globals=[]
      --toitdoc=null
      --category=null

/** Creates a top-level doc fixture. */
make-doc --libraries/Map -> Map:
  return (Doc
      --sdk-version="v2.0.0"
      --sdk-path=["path", "to", "sdk"]
      --version=null
      --pkg-name=null
      --packages-path=null
      --package-names=null
      --libraries=libraries).to-json

/// Builds a minimal toitdoc JSON fixture for the "sdk" scope.
build-sdk-fixture -> Map:
  list-class := make-class "List" "A growable list."
  collections-module := make-module "collections" --classes=[list-class]

  return make-doc --libraries={
    "core": Library
        --name="core"
        --path=["core"]
        --libraries={
          "collections": Library
              --name="collections"
              --path=["core", "collections"]
              --libraries={:}
              --modules={"collections": collections-module}
              --category=null,
        }
        --modules={:}
        --category=null,
  }

/// Builds a minimal toitdoc JSON fixture for a "package" scope.
build-pkg-fixture -> Map:
  client-class := make-class "Client" "An MQTT client."
  mqtt-module := make-module "mqtt" --classes=[client-class]

  return make-doc --libraries={
    "mqtt": Library
        --name="mqtt"
        --path=["mqtt"]
        --libraries={:}
        --modules={"mqtt": mqtt-module}
        --category=null,
  }

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

/// Tests the full MCP session: initialize, tools/list, search, get_element, list_libraries.
test-full-session:
  store := DocStore
  store.add --scope="sdk" --json=(build-sdk-fixture)

  input := io.Buffer
  input.write (frame-message (build-initialize-request --id=1))
  input.write (frame-message (build-initialized-notification))
  // List tools.
  input.write (frame-message {
    "jsonrpc": "2.0",
    "id": 2,
    "method": "tools/list",
  })
  // Search for "List".
  input.write (frame-message {
    "jsonrpc": "2.0",
    "id": 3,
    "method": "tools/call",
    "params": {
      "name": "search_docs",
      "arguments": {"query": "List"},
    },
  })
  // Get element.
  input.write (frame-message {
    "jsonrpc": "2.0",
    "id": 4,
    "method": "tools/call",
    "params": {
      "name": "get_element",
      "arguments": {"library_path": "core.collections", "element": "List"},
    },
  })
  // List libraries.
  input.write (frame-message {
    "jsonrpc": "2.0",
    "id": 5,
    "method": "tools/call",
    "params": {
      "name": "list_libraries",
      "arguments": {:},
    },
  })

  reader := io.Reader input.bytes
  output := io.Buffer
  server := create-mcp-server --store=store --reader=reader --writer=output
  server.run

  response-reader := io.Reader output.bytes

  // Response 1: initialize.
  r1 := read-response response-reader
  expect-equals 1 r1["id"]
  result1 := r1["result"] as Map
  expect (result1.contains "protocolVersion")

  // Response 2: tools/list — should have 5 tools now.
  r2 := read-response response-reader
  expect-equals 2 r2["id"]
  result2 := r2["result"] as Map
  tools := result2["tools"] as List
  expect-equals 5 tools.size
  tool-names := tools.map: | t/Map | t["name"]
  expect (tool-names.contains "load_documentation")
  expect (tool-names.contains "list_sources")
  expect (tool-names.contains "search_docs")
  expect (tool-names.contains "get_element")
  expect (tool-names.contains "list_libraries")

  // Response 3: search_docs for "List".
  r3 := read-response response-reader
  expect-equals 3 r3["id"]
  text3 := (((r3["result"] as Map)["content"] as List)[0] as Map)["text"] as string
  expect (text3.contains "List")

  // Response 4: get_element for "List".
  r4 := read-response response-reader
  expect-equals 4 r4["id"]
  text4 := (((r4["result"] as Map)["content"] as List)[0] as Map)["text"] as string
  expect (text4.contains "List")
  expect (text4.contains "class")

  // Response 5: list_libraries.
  r5 := read-response response-reader
  expect-equals 5 r5["id"]
  text5 := (((r5["result"] as Map)["content"] as List)[0] as Map)["text"] as string
  expect (text5.contains "collections")

/// Tests scoped search across multiple loaded sources.
test-scoped-search:
  store := DocStore
  store.add --scope="sdk" --json=(build-sdk-fixture)
  store.add --scope="mqtt" --json=(build-pkg-fixture)

  input := io.Buffer
  input.write (frame-message (build-initialize-request --id=1))
  input.write (frame-message (build-initialized-notification))
  // Search all scopes for "Client".
  input.write (frame-message {
    "jsonrpc": "2.0",
    "id": 2,
    "method": "tools/call",
    "params": {
      "name": "search_docs",
      "arguments": {"query": "Client"},
    },
  })
  // Search only SDK scope for "Client" — should not find it.
  input.write (frame-message {
    "jsonrpc": "2.0",
    "id": 3,
    "method": "tools/call",
    "params": {
      "name": "search_docs",
      "arguments": {"query": "Client", "scope": "sdk"},
    },
  })

  reader := io.Reader input.bytes
  output := io.Buffer
  server := create-mcp-server --store=store --reader=reader --writer=output
  server.run

  response-reader := io.Reader output.bytes
  read-response response-reader  // skip initialize

  // All-scope search: should find Client.
  r2 := read-response response-reader
  text2 := (((r2["result"] as Map)["content"] as List)[0] as Map)["text"] as string
  expect (text2.contains "Client")

  // SDK-only search: should NOT find Client.
  r3 := read-response response-reader
  text3 := (((r3["result"] as Map)["content"] as List)[0] as Map)["text"] as string
  expect (text3.contains "No results found")

/// Tests list_sources tool.
test-list-sources:
  store := DocStore
  store.add --scope="sdk" --json=(build-sdk-fixture)
  store.add --scope="mqtt" --json=(build-pkg-fixture)

  input := io.Buffer
  input.write (frame-message (build-initialize-request --id=1))
  input.write (frame-message (build-initialized-notification))
  input.write (frame-message {
    "jsonrpc": "2.0",
    "id": 2,
    "method": "tools/call",
    "params": {
      "name": "list_sources",
      "arguments": {:},
    },
  })

  reader := io.Reader input.bytes
  output := io.Buffer
  server := create-mcp-server --store=store --reader=reader --writer=output
  server.run

  response-reader := io.Reader output.bytes
  read-response response-reader  // skip initialize

  r2 := read-response response-reader
  text2 := (((r2["result"] as Map)["content"] as List)[0] as Map)["text"] as string
  expect (text2.contains "sdk")
  expect (text2.contains "mqtt")

/// Tests that calling an unknown tool returns an error.
test-unknown-tool-integration:
  store := DocStore

  input := io.Buffer
  input.write (frame-message (build-initialize-request --id=1))
  input.write (frame-message (build-initialized-notification))
  input.write (frame-message {
    "jsonrpc": "2.0",
    "id": 2,
    "method": "tools/call",
    "params": {
      "name": "nonexistent_tool",
      "arguments": {:},
    },
  })

  reader := io.Reader input.bytes
  output := io.Buffer
  server := create-mcp-server --store=store --reader=reader --writer=output
  server.run

  response-reader := io.Reader output.bytes
  read-response response-reader  // skip initialize

  r2 := read-response response-reader
  expect-equals true (r2["result"] as Map)["isError"]

/// Tests searching for a nonexistent term.
test-search-no-results-integration:
  store := DocStore
  store.add --scope="sdk" --json=(build-sdk-fixture)

  input := io.Buffer
  input.write (frame-message (build-initialize-request --id=1))
  input.write (frame-message (build-initialized-notification))
  input.write (frame-message {
    "jsonrpc": "2.0",
    "id": 2,
    "method": "tools/call",
    "params": {
      "name": "search_docs",
      "arguments": {"query": "Zzzzxyzzy"},
    },
  })

  reader := io.Reader input.bytes
  output := io.Buffer
  server := create-mcp-server --store=store --reader=reader --writer=output
  server.run

  response-reader := io.Reader output.bytes
  read-response response-reader  // skip initialize

  r2 := read-response response-reader
  text2 := (((r2["result"] as Map)["content"] as List)[0] as Map)["text"] as string
  expect (text2.contains "No results found")
