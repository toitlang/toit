// Copyright (C) 2019 Toitware ApS. All rights reserved.

import reader show BufferedReader
import .rpc show RpcConnection
import .uri_path_translator

import .utils show FakePipe
import .server show LspServer
import .file_server show sdk_path_from_compiler

import host.pipe
import monitor
import host.file

with_lsp_client [block]
    --toitc/string
    --lsp_server/string?  // Can be null if not spawning.
    --compiler_exe/string = toitc
    --toitlsp_exe/string?=null
    --supports_config=true
    --needs_server_args=(not supports_config)
    --use_rpc_filesystem=false
    --spawn_process=false:
  with_lsp_client block
      --toitc=toitc
      --lsp_server=lsp_server
      --compiler_exe=compiler_exe
      --supports_config=supports_config
      --needs_server_args=needs_server_args
      --use_rpc_filesystem=use_rpc_filesystem
      --spawn_process=spawn_process
      --pre_initialize=(:null)

with_lsp_client [block]
    --toitc/string
    --lsp_server/string?  // Can be null if not spawning.
    --toitlsp_exe/string?=null
    --compiler_exe/string = toitc
    --supports_config=true
    --needs_server_args=(not supports_config)
    --use_rpc_filesystem=false
    --spawn_process=true
    [--pre_initialize]:
  server_args := [lsp_server]
  if needs_server_args: server_args.add compiler_exe

  server_cmd/string := ?
  if toitlsp_exe:
    server_cmd = toitlsp_exe
    server_args = ["--toitc", compiler_exe, "--sdk", (sdk_path_from_compiler toitc)]
    use_rpc_filesystem = false
  else:
    server_cmd = toitc

  client := LspClient.start
      server_cmd
      server_args
      --supports_config=supports_config
      --use_rpc_filesystem=use_rpc_filesystem
      --compiler_exe=compiler_exe
      --spawn_process=spawn_process
  client.initialize pre_initialize

  try:
    block.call client
  finally:
    client.send_shutdown
    if spawn_process: client.send_exit

class LspClient:
  connection_      /RpcConnection ::= ?
  toitc            /string        ::= ?
  supports_config_ /bool          ::= false

  handlers_ /Map ::= {:}

  version_map_ /Map ::= {:}

  translator_ /UriPathTranslator ::= UriPathTranslator

  diagnostics_ /Map ::= {:}

  idle_semaphore_ /monitor.Semaphore? := null

  // By default always wait for idle after sending something to the server.
  always_wait_for_idle /bool := true

  configuration := ?

  // Will be set as result of calling initialize.
  initialize_result /Map? := null

  /**
  The language server.
  Only set, when the client was configured with `--no-spawn_process`.
  */
  server/LspServer? ::= ?

  constructor.internal_ .connection_ .toitc .supports_config_ --.server:
    configuration =  {
      "toitPath": toitc,
      "shouldWriteReproOnCrash": true,
      "timeoutMs": 5_000,  // Increase the timeout to avoid flaky tests.
    }

  static start_server_ cmd args compiler_exe --spawn_process/bool --use_rpc_filesystem/bool -> List:
    if use_rpc_filesystem:
      args += ["--rpc-filesystem"]
    print "starting the server $cmd with $args"
    if spawn_process:
      pipes := pipe.fork
          true                // use_path
          pipe.PIPE_CREATED   // stdin
          pipe.PIPE_CREATED   // stdout
          pipe.PIPE_INHERITED // stderr
          cmd
          [cmd] + args
      server_to   := pipes[0]
      server_from := pipes[1]
      pid         := pipes[3]
      pipe.dont_wait_for pid
      return [server_to, server_from]
    else:
      server_from := FakePipe
      server_to   := FakePipe
      server_rpc_connection := RpcConnection (BufferedReader server_to) server_from
      server := LspServer server_rpc_connection compiler_exe UriPathTranslator
          --use_rpc_filesystem=use_rpc_filesystem
      task::
        catch --trace: server.run
      return [server_to, server_from, server]


  static start -> LspClient
      server_cmd/string
      server_args/List
      --supports_config/bool
      --use_rpc_filesystem/bool
      --compiler_exe=server_cmd
      --spawn_process:
    start_result := start_server_ server_cmd server_args compiler_exe
        --spawn_process=spawn_process
        --use_rpc_filesystem=use_rpc_filesystem
    server_to   := start_result[0]
    server_from := start_result[1]
    server := spawn_process ? null : start_result[2]
    reader := BufferedReader server_from
    writer := server_to
    rpc_connection := RpcConnection reader writer
    client := LspClient.internal_ rpc_connection compiler_exe supports_config --server=server
    client.run_
    return client

  to_uri path/string -> string: return translator_.to_uri path
  to_path uri/string -> string: return translator_.to_path uri

  run_:
    task:: catch --trace:
      while true:
        parsed := connection_.read
        if parsed == null: break
        task:: catch --trace:
          method := parsed["method"]
          params := parsed.get "params"
          response := handle_ method params
          is_request := parsed.contains "id"
          if is_request:
            id := parsed["id"]
            connection_.reply id response

  fetch_configuration_ params:
    items := params["items"]
    assert: items.size == 1
    if items[0]["section"] != "toitLanguageServer":
      return [null]
    return [configuration]

  initialize:
    initialize: null

  initialize [pre_initialize]:
    print "initializing the server"
    initialize_params :=  {
      "capabilities": {
        "workspace": {
          "configuration": supports_config_
        },
        "experimental": {
          "ubjsonRpc": true
        }
      }
    }
    pre_initialize.call this initialize_params
    initialize_result = connection_.request "initialize" initialize_params
    print "initialized"
    connection_.send "initialized" {:}

  /**
  Installs [callback] as handler for the given [method].

  If [callback] is `null` removes the existing handler.
  */
  install_handler method/string callback/Lambda? -> none:
    if callback:
      handlers_[method] = callback
    else:
      handlers_.remove method

  handle_ method/string params/Map? -> any:
    handlers_.get method --if_present=: return it.call params
    default_handlers := {
      "textDocument/publishDiagnostics": (:: handle_diagnostics_ params),
      "toit/idle": (:: handle_idle_ params),
      "workspace/configuration": (:: fetch_configuration_ params),
      "window/showMessage": (:: handle_show_message_ params),
    }
    default_handlers.get method --if_present=: return it.call params
    return null // Currently just return null.

  wait_for_idle -> none:
    // Currently we only support one waiter on idle.
    assert: idle_semaphore_ == null
    idle_semaphore_ = monitor.Semaphore
    connection_.send "toit/report_idle" null
    idle_semaphore_.down

  handle_idle_ msg -> none:
    semaphore := idle_semaphore_
    idle_semaphore_ = null
    semaphore.up

  handle_show_message_ msg -> none:
    // Don't just ignore crash messages. Any user of the client that doesn't
    //   install a show-message handler that deals with crashes will get
    //   aborted. This makes tests less prone to accidentally succeed.
    message := msg["message"]
    print "received message: $message"
    if message.contains "crashed":
      exit 1

  diagnostics_for --path/string -> List?: return diagnostics_for --uri=(translator_.to_uri path)
  diagnostics_for --uri/string -> List?:
    return diagnostics_.get uri

  clear_diagnostics:
    diagnostics_.clear

  handle_diagnostics_ params/Map? -> none:
    uri := params["uri"]
    diagnostics_[uri] = params["diagnostics"]

  send_cancel id/any -> none:
    connection_.send "\$/cancelRequest" { "id": id }

  send_did_open --path/string --text=null -> none:
    send_did_open_ --path=path --uri=(to_uri path) --text=text

  send_did_open --uri/string --text=null -> none:
    send_did_open_ --path=null --uri=uri --text=text

  send_did_open_ --path/string? --uri/string? --text=null -> none:
    version := version_map_.update uri --if_absent=(: 1): it + 1
    if text == null:
      assert: path != null
      text = (file.read_content path).to_string
    connection_.send "textDocument/didOpen" {
      "textDocument": {
        "uri": uri,
        "languageId": "toit",
        "version": version,
        "text": text,
      }
    }
    if always_wait_for_idle: wait_for_idle

  send_did_open_many --paths/List -> none:
    uris := paths.map: to_uri it
    send_did_open_many --uris=uris

  send_did_open_many --uris/List -> none:
    connection_.send "toit/didOpenMany" { "uris": uris }
    if always_wait_for_idle: wait_for_idle

  send_did_close --path -> none:
    uri := to_uri path
    connection_.send "textDocument/didClose" {
      "textDocument": {
        "uri": uri,
      }
    }
    if always_wait_for_idle: wait_for_idle

  send_did_save --path -> none:
    uri := to_uri path
    connection_.send "textDocument/didSave" {
      "textDocument": {
        "uri": uri,
      }
    }
    if always_wait_for_idle: wait_for_idle

  send_did_change --path/string content -> none:
    send_did_change --uri=(to_uri path) content

  send_did_change --uri/string content -> none:
    version := version_map_.update uri --if_absent=(: 0): it + 1
    connection_.send "textDocument/didChange" {
      "textDocument": {
        "uri": uri,
        "version": version,
      },
      "contentChanges": [
        { "text": content },
      ]
    }
    if always_wait_for_idle: wait_for_idle

  send_completion_request --path/string line column -> any:
    return send_completion_request --uri=(to_uri path) line column

  send_completion_request --uri/string line column -> any:
    return send_completion_request --uri=uri line column --id_callback=: null

  send_completion_request --uri/string line column [--id_callback] -> any:
    result := connection_.request
        --id_callback=id_callback
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
    if always_wait_for_idle: wait_for_idle
    return result


  send_goto_definition_request --path/string line column -> any:
    return send_goto_definition_request --uri=(to_uri path) line column

  send_goto_definition_request --uri/string line column -> any:
    result := connection_.request "textDocument/definition" {
      "textDocument": {
        "uri": uri
      },
      "position": {
        "line": line,
        "character": column,
      }
    }
    if always_wait_for_idle: wait_for_idle
    return result

  send_outline_request --path/string -> any: return send_outline_request --uri=(to_uri path)

  send_outline_request --uri/string -> any:
    result := connection_.request "textDocument/documentSymbol" {
      "textDocument": {
        "uri": uri
      }
    }
    if always_wait_for_idle: wait_for_idle
    return result

  send_semantic_tokens_request --path/string -> any:
    return send_semantic_tokens_request --uri=(to_uri path)

  send_semantic_tokens_request --uri/string -> any:
    result := connection_.request "textDocument/semanticTokens/full" {
      "textDocument": {
        "uri": uri
      }
    }
    if always_wait_for_idle: wait_for_idle
    return result

  send_reset_crash_rate_limit -> none:
    connection_.send "toit/reset_crash_rate_limit" null

  send_request method/string arg/any -> any:
    return connection_.request method arg

  send_shutdown:
    connection_.request "shutdown" null

  send_exit:
    connection_.send "exit" null
