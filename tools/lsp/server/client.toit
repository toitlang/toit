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

import reader show BufferedReader
import .rpc show RpcConnection
import .uri-path-translator

import .utils show FakePipe
import .server show LspServer
import .file-server show sdk-path-from-compiler

import host.pipe
import monitor
import host.file

with-lsp-client [block]
    --toitc/string
    --lsp-server/string?  // Can be null if not spawning.
    --compiler-exe/string = toitc
    --toitlsp-exe/string?=null
    --supports-config=true
    --needs-server-args=(not supports-config)
    --spawn-process=false:
  with-lsp-client block
      --toitc=toitc
      --lsp-server=lsp-server
      --compiler-exe=compiler-exe
      --supports-config=supports-config
      --needs-server-args=needs-server-args
      --spawn-process=spawn-process
      --pre-initialize=(:null)

with-lsp-client [block]
    --toitc/string
    --lsp-server/string?  // Can be null if not spawning.
    --toitlsp-exe/string?=null
    --compiler-exe/string = toitc
    --supports-config=true
    --needs-server-args=(not supports-config)
    --spawn-process=true
    [--pre-initialize]:
  server-args := [lsp-server]
  if needs-server-args: server-args.add compiler-exe

  server-cmd/string := ?
  if toitlsp-exe:
    server-cmd = toitlsp-exe
    server-args = ["--toitc", compiler-exe, "--sdk", (sdk-path-from-compiler toitc)]
  else:
    server-cmd = toitc

  client := LspClient.start
      server-cmd
      server-args
      --supports-config=supports-config
      --compiler-exe=compiler-exe
      --spawn-process=spawn-process
  client.initialize pre-initialize

  try:
    block.call client
  finally:
    client.send-shutdown
    if spawn-process: client.send-exit

class LspClient:
  connection_      /RpcConnection ::= ?
  toitc            /string        ::= ?
  supports-config_ /bool          ::= false

  handlers_ /Map ::= {:}

  version-map_ /Map ::= {:}

  translator_ /UriPathTranslator ::= UriPathTranslator

  diagnostics_ /Map ::= {:}

  idle-semaphore_ /monitor.Semaphore? := null

  // By default always wait for idle after sending something to the server.
  always-wait-for-idle /bool := true

  configuration := ?

  // Will be set as result of calling initialize.
  initialize-result /Map? := null

  /**
  The language server.
  Only set, when the client was configured with `--no-spawn_process`.
  */
  server/LspServer? ::= ?

  /**
  The language server process ID.
  Only set, when the client was configured without `--spawn_process`.
  */
  server-pid ::= ?

  constructor.internal_ .connection_ .toitc .supports-config_ --.server --.server-pid=null:
    configuration =  {
      "toitPath": toitc,
      "shouldWriteReproOnCrash": true,
      "timeoutMs": 10_000,  // Increase the timeout to avoid flaky tests.
    }

  static start-server_ cmd args compiler-exe --spawn-process/bool -> List:
    print "starting the server $cmd with $args"
    if spawn-process:
      pipes := pipe.fork
          true                // use_path
          pipe.PIPE-CREATED   // stdin
          pipe.PIPE-CREATED   // stdout
          pipe.PIPE-INHERITED // stderr
          cmd
          [cmd] + args
      server-to   := pipes[0]
      server-from := pipes[1]
      pid         := pipes[3]
      return [server-to, server-from, null, pid]
    else:
      server-from := FakePipe
      server-to   := FakePipe
      server-rpc-connection := RpcConnection (BufferedReader server-to) server-from
      server := LspServer server-rpc-connection compiler-exe UriPathTranslator
      task::
        server.run
      return [server-to, server-from, server, null]


  static start -> LspClient
      server-cmd/string
      server-args/List
      --supports-config/bool
      --compiler-exe=server-cmd
      --spawn-process:
    start-result := start-server_ server-cmd server-args compiler-exe
        --spawn-process=spawn-process
    server-to   := start-result[0]
    server-from := start-result[1]
    server := start-result[2]
    reader := BufferedReader server-from
    writer := server-to
    rpc-connection := RpcConnection reader writer
    client := LspClient.internal_ rpc-connection compiler-exe supports-config --server=server --server-pid=start-result[3]
    client.run_
    return client

  to-uri path/string -> string: return translator_.to-uri path
  to-path uri/string -> string: return translator_.to-path uri

  run_:
    task::
      while true:
        parsed := connection_.read
        if parsed == null: break
        task::
          method := parsed["method"]
          params := parsed.get "params"
          response := handle_ method params
          is-request := parsed.contains "id"
          if is-request:
            id := parsed["id"]
            connection_.reply id response
      if server-pid:
        exit-value := pipe.wait-for server-pid
        exit-signal := pipe.exit-signal exit-value
        exit-code := pipe.exit-code exit-value
        if exit-signal:
          throw "LSP server exited with signal $exit-signal"
        if exit-code != 0:
          throw "LSP server exited with exit code $exit-code"

  fetch-configuration_ params:
    items := params["items"]
    assert: items.size == 1
    if items[0]["section"] != "toitLanguageServer":
      return [null]
    return [configuration]

  initialize:
    initialize: null

  initialize [pre-initialize]:
    print "initializing the server"
    initialize-params :=  {
      "capabilities": {
        "workspace": {
          "configuration": supports-config_
        },
        "experimental": {
          "ubjsonRpc": true
        }
      }
    }
    pre-initialize.call this initialize-params
    initialize-result = connection_.request "initialize" initialize-params
    print "initialized"
    connection_.send "initialized" {:}

  /**
  Installs [callback] as handler for the given [method].

  If [callback] is `null` removes the existing handler.
  */
  install-handler method/string callback/Lambda? -> none:
    if callback:
      handlers_[method] = callback
    else:
      handlers_.remove method

  handle_ method/string params/Map? -> any:
    handlers_.get method --if-present=: return it.call params
    default-handlers := {
      "textDocument/publishDiagnostics": (:: handle-diagnostics_ params),
      "toit/idle": (:: handle-idle_ params),
      "workspace/configuration": (:: fetch-configuration_ params),
      "window/showMessage": (:: handle-show-message_ params),
    }
    default-handlers.get method --if-present=: return it.call params
    return null // Currently just return null.

  wait-for-idle -> none:
    // Currently we only support one waiter on idle.
    assert: idle-semaphore_ == null
    idle-semaphore_ = monitor.Semaphore
    connection_.send "toit/report_idle" null
    idle-semaphore_.down

  handle-idle_ msg -> none:
    semaphore := idle-semaphore_
    idle-semaphore_ = null
    semaphore.up

  handle-show-message_ msg -> none:
    // Don't just ignore crash messages. Any user of the client that doesn't
    //   install a show-message handler that deals with crashes will get
    //   aborted. This makes tests less prone to accidentally succeed.
    message := msg["message"]
    print "received message: $message"
    if message.contains "crashed":
      exit 1

  diagnostics-for --path/string -> List?: return diagnostics-for --uri=(translator_.to-uri path)
  diagnostics-for --uri/string -> List?:
    return diagnostics_.get uri

  clear-diagnostics:
    diagnostics_.clear

  handle-diagnostics_ params/Map? -> none:
    uri := params["uri"]
    diagnostics_[uri] = params["diagnostics"]

  send-cancel id/any -> none:
    connection_.send "\$/cancelRequest" { "id": id }

  send-did-open --path/string --text=null -> none:
    send-did-open_ --path=path --uri=(to-uri path) --text=text

  send-did-open --uri/string --text=null -> none:
    send-did-open_ --path=null --uri=uri --text=text

  send-did-open_ --path/string? --uri/string? --text=null -> none:
    version := version-map_.update uri --if-absent=(: 1): it + 1
    if text == null:
      assert: path != null
      text = (file.read-content path).to-string
    connection_.send "textDocument/didOpen" {
      "textDocument": {
        "uri": uri,
        "languageId": "toit",
        "version": version,
        "text": text,
      }
    }
    if always-wait-for-idle: wait-for-idle

  send-did-open-many --paths/List -> none:
    uris := paths.map: to-uri it
    send-did-open-many --uris=uris

  send-did-open-many --uris/List -> none:
    connection_.send "toit/didOpenMany" { "uris": uris }
    if always-wait-for-idle: wait-for-idle

  send-did-close --path -> none:
    uri := to-uri path
    connection_.send "textDocument/didClose" {
      "textDocument": {
        "uri": uri,
      }
    }
    if always-wait-for-idle: wait-for-idle

  send-did-save --path -> none:
    uri := to-uri path
    connection_.send "textDocument/didSave" {
      "textDocument": {
        "uri": uri,
      }
    }
    if always-wait-for-idle: wait-for-idle

  send-did-change --path/string content -> none:
    send-did-change --uri=(to-uri path) content

  send-did-change --uri/string content -> none:
    version := version-map_.update uri --if-absent=(: 0): it + 1
    connection_.send "textDocument/didChange" {
      "textDocument": {
        "uri": uri,
        "version": version,
      },
      "contentChanges": [
        { "text": content },
      ]
    }
    if always-wait-for-idle: wait-for-idle

  send-completion-request --path/string line column -> any:
    return send-completion-request --uri=(to-uri path) line column

  send-completion-request --uri/string line column -> any:
    return send-completion-request --uri=uri line column --id-callback=: null

  send-completion-request --uri/string line column [--id-callback] -> any:
    result := connection_.request
        --id-callback=id-callback
        "textDocument/completion"
        {
          "context": {
            "trigger_kind": 1
          },
          "textDocument": {
            "uri": uri
          },
          "position": {
            "line": line,
            "character": column,
          }
        }
    if always-wait-for-idle: wait-for-idle
    return result


  send-goto-definition-request --path/string line column -> any:
    return send-goto-definition-request --uri=(to-uri path) line column

  send-goto-definition-request --uri/string line column -> any:
    result := connection_.request "textDocument/definition" {
      "textDocument": {
        "uri": uri
      },
      "position": {
        "line": line,
        "character": column,
      }
    }
    if always-wait-for-idle: wait-for-idle
    return result

  send-outline-request --path/string -> any: return send-outline-request --uri=(to-uri path)

  send-outline-request --uri/string -> any:
    result := connection_.request "textDocument/documentSymbol" {
      "textDocument": {
        "uri": uri
      }
    }
    if always-wait-for-idle: wait-for-idle
    return result

  send-semantic-tokens-request --path/string -> any:
    return send-semantic-tokens-request --uri=(to-uri path)

  send-semantic-tokens-request --uri/string -> any:
    result := connection_.request "textDocument/semanticTokens/full" {
      "textDocument": {
        "uri": uri
      }
    }
    if always-wait-for-idle: wait-for-idle
    return result

  send-reset-crash-rate-limit -> none:
    connection_.send "toit/reset_crash_rate_limit" null

  send-request method/string arg/any -> any:
    return connection_.request method arg

  send-shutdown:
    connection_.request "shutdown" null

  send-exit:
    connection_.send "exit" null
