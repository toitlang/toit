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

import core as core
import cli
import encoding.json as json
import encoding.base64 as base64
import reader show BufferedReader
import host.file
import host.directory
import host.pipe
import bytes

import .protocol.change
import .protocol.completion
import .protocol.configuration
import .protocol.experimental
import .protocol.diagnostic
import .protocol.document
import .protocol.document_symbol
import .protocol.initialization
import .protocol.message
import .protocol.server_capabilities
import .protocol.semantic_tokens
import .protocol_toit

import .compiler
import .documents
import .file_server
import .repro
import .rpc
import .uri_path_translator
import .utils
import .verbose

DEFAULT_SETTINGS /Map ::= {:}
DEFAULT_TIMEOUT_MS ::= 10_000
DEFAULT_REPRO_DIR ::= "/tmp/lsp_repros"
CRASH_REPORT_RATE_LIMIT_MS ::= 30_000

monitor Settings:
  map_ /Map := DEFAULT_SETTINGS

  get key: return get key --if_absent=: null

  get key [--if_absent]:
    return map_.get key --if_absent=if_absent

  // While the new values are fetched, all other requests to the settings are blocked.
  replace [b] -> none:
    replacement_map := b.call
    // The client is allowed to return `null` if it doesn't have
    // any configuration for the settings we requested.
    if replacement_map: map_ = replacement_map

  replace new_map/Map -> none: map_ = new_map

class LspServer:
  documents_     /Documents         ::= ?
  connection_    /RpcConnection     ::= ?
  translator_    /UriPathTranslator ::= ?
  toit_path_override_  /string?     ::= ?
  uses_rpc_filesystem_ /bool        ::= ?
  /// The placeholder for the compiler's SDK path.
  /// When null uses the client's SDK libraries.
  /// Otherwise the placeholder is replaced with the compiler's SDK library path.
  rpc_sdk_path_placeholder_  /string? ::= ?
  /// The root uri of the workspace.
  /// Rarely needed, as the server generally works with absolute paths.
  /// It's mainly used to find package.lock files.
  root_uri_ /string? := null

  active_requests_ := 0
  on_idle_callbacks_ := []

  next_analysis_revision_ := 0

  client_supports_configuration_ := false
  /// The settings from the client (or, if not supported, default settings).
  settings_ /Settings := Settings

  last_crash_report_time_ := null

  /// A set of open request-ids
  /// When a request is canceled, it is removed from the set, so
  ///   that we don't respond multiple times.
  open_requests_ /Set := {}

  constructor
      .connection_
      .toit_path_override_
      .translator_
      --use_rpc_filesystem/bool
      --rpc_sdk_path_placeholder/string?=null:
    documents_ = Documents translator_
    uses_rpc_filesystem_ = use_rpc_filesystem
    rpc_sdk_path_placeholder_ = rpc_sdk_path_placeholder

  run -> none:
    while true:
      parsed := connection_.read
      if parsed == null: return
      id := parsed.get "id"
      if id: open_requests_.add id
      task:: catch --trace:
        active_requests_++
        method := parsed["method"]
        params := parsed.get "params"
        verbose: "Request for $method $id"
        response := handle_ method params
        verbose: "Request $method $id handled"
        if id and (open_requests_.contains id):
          open_requests_.remove id
          connection_.reply id response
        active_requests_--
        if active_requests_ == 0 and not on_idle_callbacks_.is_empty:
          callbacks := on_idle_callbacks_
          on_idle_callbacks_ = []
          callbacks.do: it.call

  handle_ method/string params/Map? -> any:
    // TODO(florian): this should be a switch or something.
    handlers ::= {
        "initialize":              (:: initialize (InitializeParams it)),
        "initialized":             (:: initialized),
        "\$/cancelRequest":        (:: cancel     (CancelParams it)),
        "textDocument/didOpen":    (:: did_open   (DidOpenTextDocumentParams   it)),
        "textDocument/didChange":  (:: did_change (DidChangeTextDocumentParams it)),
        "textDocument/didSave":    (:: did_save   (DidSaveTextDocumentParams   it)),
        "textDocument/didClose":   (:: did_close  (DidCloseTextDocumentParams   it)),
        "textDocument/completion": (:: completion (CompletionParams it )),
        "textDocument/definition": (:: goto_definition (TextDocumentPositionParams it)),
        "textDocument/documentSymbol": (:: document_symbol (DocumentSymbolParams it)),
        "textDocument/semanticTokens/full": (:: semantic_tokens (SemanticTokensParams it)),
        "shutdown":                (:: shutdown),
        "exit":                    (:: exit),
        "toit/report_idle":        (:: report_idle),
        "toit/reset_crash_rate_limit": (:: reset_crash_rate_limit),
        "toit/settings":           (:: settings_.map_),
        "toit/didOpenMany":        (:: did_open_many it),
        "toit/fetchSdkFile":       (:: fetch_sdk_file (FetchSdkFileParams it)),
        "toit/archive":            (:: archive (ArchiveParams it)),
        "toit/snapshot_bundle":    (:: snapshot_bundle (SnapshotBundleParams it))
    }
    handlers.get method --if_present=: return it.call params

    verbose: "Unknown/unimplemented method $method"
    return ResponseError
        --code=ErrorCodes.method_not_found
        --message="Unknown or unimplemented method $method"

  /**
  Initializes the server with the client-information and responds with
    the server capabilities.
  */
  initialize params/InitializeParams -> InitializationResult:
    capabilities := params.capabilities
    client_supports_configuration_ = capabilities.workspace != null and capabilities.workspace.configuration
    root_uri_ = params.root_uri
    // Process experimental features, some implemented by us.
    if params.capabilities.experimental:
      if params.capabilities.experimental.ubjson_rpc: connection_.enable_ubjson

    server_capabilities := ServerCapabilities
        --completion_provider= CompletionOptions
            --resolve_provider=   false
            --trigger_characters= [".", "-", "\$"]
        --definition_provider=      true
        --document_symbol_provider= true
        --text_document_sync= TextDocumentSyncOptions
            --open_close
            --change= TextDocumentSyncKind.full
            --save=   SaveOptions --no-include_text
        --semantic_tokens_provider= SemanticTokensOptions
            --legend= SemanticTokensLegend
                --token_types= Compiler.SEMANTIC_TOKEN_TYPES
                --token_modifiers= Compiler.SEMANTIC_TOKEN_MODIFIERS
            --no-range
            --full= true  // Or should it be '{ "delta": false }' ?
        --experimental=Experimental --ubjson_rpc

    return InitializationResult server_capabilities

  initialized -> none:
    // Get the settings, in case the client supports configuration. (Otherwise they are already filled
    //   with default values).
    if client_supports_configuration_:
      settings_.replace: request_settings
      // Client configurations can only make the output verbose, but not disable it,
      //   if it was given by command-line.
      is_verbose = is_verbose or (settings_.get "verbose" --if_absent=: false) == true
    // TODO(florian): register DidChangeConfigurationNotification.type

  cancel params/CancelParams -> none:
    id := params.id
    task := open_requests_.get id
    if task:
      open_requests_.remove id
      connection_.reply id
          ResponseError
            --code=ErrorCodes.request_cancelled
            --message="Cancelled on request"

  did_open params/DidOpenTextDocumentParams -> none:
    document := params.text_document
    uri := translator_.canonicalize document.uri
    // We are calling `analyze` just after updating the document.
    // The next analysis-revision is thus the one where the new content has been
    //   taken into account.
    content_revision := next_analysis_revision_
    documents_.did_open --uri=uri document.text content_revision
    analyze [uri]

  did_open_many params -> none:
    uris := params["uris"]
    uris = uris.map: translator_.canonicalize it
    content_revision := next_analysis_revision_
    uris.do:
      content := null
      documents_.did_open --uri=it content content_revision
    analyze uris

  fetch_sdk_file params/FetchSdkFileParams -> Map:
    path := params.path
    if not uses_rpc_filesystem_ or not rpc_sdk_path_placeholder_:
      throw "fetch_sdk_file only permitted when running with rpc sdk path"

    if not path.starts_with rpc_sdk_path_placeholder_:
      throw "fetch_sdk_file called with non sdk path: '$path'"

    sdk_path := (sdk_path_from_compiler compiler_path_)
    local_path := path.replace rpc_sdk_path_placeholder_ sdk_path

    protocol := FileServerProtocol.local compiler_path_ sdk_path_ documents_
    file := protocol.get_file local_path
    content/any := file.content
    if content and connection_.uses_json: content = content.to_string
    return {
      "path": file.path,
      "exists": file.exists,
      "is_regular": file.is_regular,
      "is_directory": file.is_directory,
      "content": content,
    }

  archive params/ArchiveParams -> string:
    non_canonicalized_uris := params.uris or [params.uri]
    // If the request doesn't specify whether it wants the sdk we include it.
    include_sdk := params.include_sdk == null ? true : params.include_sdk
    uris := non_canonicalized_uris.map: translator_.canonicalize it
    paths := uris.map: translator_.to_path it
    compiler := compiler_
    compiler.parse --paths=paths
    buffer := bytes.Buffer
    write_repro
        --writer=buffer
        --compiler_flags=compiler.build_run_flags
        --compiler_input=json.stringify paths
        --protocol=compiler.protocol
        --info="toit/archive"
        --cwd_path=null
        --include_sdk=include_sdk
    byte_array := buffer.bytes
    return base64.encode byte_array

  snapshot_bundle params/SnapshotBundleParams -> Map?:
    uri := translator_.canonicalize params.uri
    compiler := compiler_
    bundle := compiler.snapshot_bundle uri
    // Encode the byte-array as base64.
    if not bundle: return null
    return {
      "snapshot_bundle": base64.encode bundle
    }

  did_close params/DidCloseTextDocumentParams -> none:
    uri := translator_.canonicalize params.text_document.uri
    documents_.did_close --uri=uri

  did_save params/DidSaveTextDocumentParams -> none:
    uri := translator_.canonicalize params.text_document.uri
    // No need to validate, since we should have gotten a `did_change` before
    //   any save (if the document was dirty).
    documents_.did_save --uri=uri

  did_change params/DidChangeTextDocumentParams -> none:
    document := params.text_document
    changes  := params.content_changes
    uri := translator_.canonicalize document.uri
    changes.do:
      assert: it.range == null  // We only support full-file updates for now.
      // We are calling `analyze` just after updating the document.
      // The next analysis-revision is thus the one where the new content has been
      //   taken into account.
      documents_.did_change --uri=uri it.text next_analysis_revision_
    analyze [uri]

  completion params/CompletionParams -> List/*<CompletionItem>*/:
    uri := translator_.canonicalize params.text_document.uri
    return compiler_.complete uri params.position.line params.position.character

  // TODO(florian): The specification supports a list of locations, or Locationlinks..
  // For now just returns one location.
  goto_definition params/TextDocumentPositionParams -> List/*<Location>*/:
    uri := translator_.canonicalize params.text_document.uri
    return compiler_.goto_definition uri params.position.line params.position.character

  document_symbol params/DocumentSymbolParams -> List/*<DocumentSymbol>*/:
    uri := translator_.canonicalize params.text_document.uri
    document := documents_.get --uri=uri
    if not (document and document.summary):
      analyze [uri]
      document = documents_.get_existing_document --uri=uri
      if not document.summary: return []
    content := ""
    if document.content:
      content = document.content
    else:
      path := translator_.to_path uri
      if file.is_file path:
        content = (file.read_content path).to_string
    if not content: return []
    return document.summary.to_lsp_document_symbol content

  semantic_tokens params/SemanticTokensParams -> SemanticTokens:
    uri := translator_.canonicalize params.text_document.uri
    tokens := compiler_.semantic_tokens uri
    return SemanticTokens --data=tokens

  shutdown:
    // Do nothing yet.
    return null

  exit:
    on_idle_callbacks_.add (:: core.exit 0)
    task:: catch --trace:
      // Force an exit in case some request is not terminating.
      sleep --ms=1000
      core.exit 1

  report_idle:
    on_idle_callbacks_.add (:: connection_.send "toit/idle" null)

  /**
  Analyzes the given $uris and sends diagnostics to the client.

  Transitively analyzes all newly discovered files.
  */
  analyze uris/List revision/int?=null -> none:
    if uris.is_empty: return

    revision = revision or next_analysis_revision_++
    assert: uris.every: | uri |
      (documents_.get_existing_document --uri=uri).analysis_revision < revision

    verbose: "Analyzing: $uris  ($revision)"

    analysis_result := compiler_.analyze uris
    if not analysis_result:
      verbose: "Analysis failed (no analysis result). ($revision)"
      return  // Analysis didn't succeed. Don't bother with the result.

    summaries := analysis_result.summaries
    diagnostics_per_uri := analysis_result.diagnostics
    // We can't send diagnostics without position to the client, but we can use it
    // to guess why a compilation failed.
    diagnostics_without_position := analysis_result.diagnostics_without_position

    if summaries == null:
      // If the diagnostics without position isn't empty, and contains something for a uri, we
      // assume that there was a problem reading the file.
      uris.do: |uri|
        entry_path := translator_.to_path uri
        probably_entry_problem := diagnostics_per_uri.is_empty and
            diagnostics_without_position.any: it.contains entry_path
        document := documents_.get --uri=uri
        if probably_entry_problem and document:
          if document.is_open:
            // This should not happen.
            // TODO(florian): report to client and log (potentially creating repro).
          else:
            if file.is_file entry_path:
              // TODO(florian): report to client and log (potentially creating repro).
            // Either way: delete the entry.
            documents_.delete --uri=uri
      // Don't use the analysis result.
      return

    // Documents for which the summary changed.
    changed_summary_documents := {}
    // Documents for which we want to report diagnostics.
    report_diagnostics_documents := {}

    // Always report diagnostics for the given uris, unless there is a more recent
    // analysis already, or if the document has been updated in the meantime.
    uris.do: | uri |
      doc := documents_.get_existing_document --uri=uri
      if not doc.analysis_revision >= revision and not doc.content_revision > revision:
        report_diagnostics_documents.add uri

    summaries.do: |summary_uri summary|
      assert: summary != null
      update_result := documents_.update_document_after_analysis --uri=summary_uri
          --analysis_revision=revision
          --summary=summary
      has_changed_summary := (update_result & Documents.SUMMARY_CHANGED_EXTERNALLY_BIT) != 0
      first_analysis_after_content_change :=
          (update_result & Documents.FIRST_ANALYSIS_AFTER_CONTENT_CHANGE_BIT) != 0

      // If the summary has changed, it either means that:
      //  - this was one of the $uris that was analyzed
      //  - the $summary_uri depends on one of the $uris (but was also reachable from them)
      //  - the $summary_uri (or one of its dependencies) was changed. This could be because
      //    of a change on disk, or because of a `did_change` call. In the latter case,
      //    there would still be another analysis running, but this one completed earlier.
      if has_changed_summary:
        changed_summary_documents.add summary_uri
      if has_changed_summary or first_analysis_after_content_change:
        report_diagnostics_documents.add summary_uri
      dep_document := documents_.get_existing_document --uri=summary_uri
      request_revision := dep_document.analysis_requested_by_revision
      if request_revision != -1 and request_revision < revision:
        report_diagnostics_documents.add summary_uri

    // All reverse dependencies of changed documents need to have their diagnostics printed.
    changed_summary_documents.do:
      document := documents_.get_existing_document --uri=it

      // Local lambda that transitively adds reverse dependencies.
      // We add all transitive dependencies, as it's hard to track implicit exports.
      // For example, the return type of a method, requires all users of the method
      //   to check whether a member call of the result is now allowed or not.
      // This can be happen multiple layers down. See #1513 for an example.
      // Note that we do this only if the summary of the initial file changes. As such, we
      //   usually don't analyze everything.
      add_rev_deps := null
      add_rev_deps = :: |rev_dep_uri|
        if not report_diagnostics_documents.contains rev_dep_uri:
          report_diagnostics_documents.add rev_dep_uri
          rev_document := documents_.get_existing_document --uri=rev_dep_uri
          rev_document.reverse_deps.do: add_rev_deps.call it

      document.reverse_deps.do: add_rev_deps.call it

    // Send the diagnostics we have to the client.
    report_diagnostics_documents.do: |uri|
      document := documents_.get_existing_document --uri=uri
      request_revision := document.analysis_requested_by_revision
      was_analyzed := summaries.contains uri
      if was_analyzed:
        diagnostics := diagnostics_per_uri.get uri --if_absent=: []
        send_diagnostics (PushDiagnosticsParams --uri=uri --diagnostics=diagnostics)
        if request_revision != -1 and request_revision < revision:
          // Mark the request as done.
          document.analysis_requested_by_revision = -1
      else if request_revision < revision:
        document.analysis_requested_by_revision = revision

    // Local lambda that returns whether a document needs analysis.
    needs_analysis := : |uri|
      document := documents_.get_existing_document --uri=uri
      up_to_date := document.analysis_revision >= revision
      will_be_analyzed := document.content_revision and document.content_revision > revision
      not up_to_date and not will_be_analyzed

    // See which documents need to be analyzed as a result of changes.
    documents_needing_analysis := report_diagnostics_documents.filter --in_place: // Reuse the set
      needs_analysis.call it

    if not documents_needing_analysis.is_empty:
      analyze (List.from documents_needing_analysis) revision

  send_diagnostics params/PushDiagnosticsParams -> none:
    connection_.send "textDocument/publishDiagnostics" params

  request_settings -> Map?:
    params := ConfigurationParams --items= [ConfigurationItem --section="toitLanguageServer"]
    configuration := connection_.request "workspace/configuration" params
    // If the client doesn't have the the requested section, the content of the
    // configuration might be `null`.
    return configuration[0]  // We only requested one configuration, but it still comes in a list.

  send_log_message msg/string -> none:
    connection_.send "window/logMessage" {"type": 4, "message": msg}

  send_show_message msg -> none:
    connection_.send "window/showMessage" {"type": 3, "message": msg}

  static repro_counter_ := 0
  compute_repro_path_ -> string:
    repro_dir := settings_.get "reproDir" --if_absent=: DEFAULT_REPRO_DIR
    repro_prefix := "$repro_dir/repro"
    if not file.is_directory repro_dir:
      if file.is_file repro_dir:
        send_show_message "Repro-dir exists and is not a directory: $repro_dir"
        // Don't overwrite the existing file.
        // We have a loop just below to find the name of the next non-existing path.
        repro_prefix = "/tmp/lsp_repro"
      else:
        directory.mkdir repro_dir
    repro_path := ""
    while true:
      repro_path = "$(repro_prefix)_$(Time.monotonic_us)-$(repro_counter_++).tar"
      if not (file.is_file repro_path or file.is_directory repro_path): break
    return repro_path

  reset_crash_rate_limit: last_crash_report_time_ = null

  compiler_path_ -> string:
    compiler_path := toit_path_override_
    if compiler_path != null:
      return compiler_path
    return settings_.get "toitPath" --if_absent=: "toit.compile"

  sdk_path_ -> string:
    // We can't access a setting while reading settings (the Setting class is a
    // monitor). Read the compiler_path first.
    compiler_path := compiler_path_
    return settings_.get "sdkPath" --if_absent=:
      sdk_path_from_compiler compiler_path

  compiler_ -> Compiler:
    compiler_path := compiler_path_
    sdk_path := sdk_path_
    timeout_ms := settings_.get "timeoutMs" --if_absent=: DEFAULT_TIMEOUT_MS

    // Rate limit crash reporting.
    is_rate_limited := false
    if last_crash_report_time_:
      current_us := Time.monotonic_us
      CRASH_LIMIT_US ::= CRASH_REPORT_RATE_LIMIT_MS * 1_000
      is_rate_limited = (Time.monotonic_us - last_crash_report_time_) <= CRASH_LIMIT_US

    should_write_repro := settings_.get "shouldWriteReproOnCrash" --if_absent=:false

    protocol / FileServerProtocol := ?
    if uses_rpc_filesystem_:
      filesystem/Filesystem := ?
      if rpc_sdk_path_placeholder_:
        filesystem = FilesystemHybrid rpc_sdk_path_placeholder_ compiler_path connection_
      else:
        filesystem = FilesystemLspRpc connection_
      protocol = FileServerProtocol documents_ filesystem
    else:
      protocol = FileServerProtocol.local compiler_path sdk_path documents_

    compiler := null  // Let the 'compiler' local be visible in the lambda expression below.
    compiler = Compiler compiler_path translator_ timeout_ms
        --protocol=protocol
        --project_path=root_uri_ and (translator_.to_path root_uri_)
        --on_error=:: |message|
          if is_rate_limited:
            // Do nothing
          else if should_write_repro:
            // We are using the same flag to send a more visible message.
            send_show_message message
          else:
            send_log_message message
        --on_crash=:: |compiler_flags compiler_input signal protocol|
          if is_rate_limited:
            // Do nothing.
          else if should_write_repro:
            repro_path := compute_repro_path_
            write_repro
                --repro_path=repro_path
                --compiler_flags=compiler_flags
                --compiler_input=compiler_input
                --info=signal
                --protocol=protocol
                --cwd_path=root_uri_ and (translator_.to_path root_uri_)
                --include_sdk
            send_show_message "Compiler crashed. Repro created: $repro_path"
          else:
            send_log_message "Compiler crashed with signal $signal"
          last_crash_report_time_ = Time.monotonic_us
    return compiler

main args -> none:
  parsed := null
  parser := cli.Command "server"
      --rest=[
          cli.OptionString "toit-path-override",
      ]
      --options=[
          cli.Flag "rpc-filesystem" --default=false,
          cli.OptionString "rpc-sdk-path",
          cli.OptionString "home-path",
          cli.OptionString "uri_path_mapping",
          cli.Flag "verbose" --default=false,
      ]
      --run=:: parsed = it
  parser.run args
  if not parsed: exit 0

  toit_path_override := parsed["toit-path-override"]

  use_rpc_filesystem := parsed["rpc-filesystem"]
  rpc_sdk_path_placeholder := parsed["rpc-sdk-path"]
  json_mapping := parsed["uri_path_mapping"]
  is_verbose = parsed["verbose"]

  uri_path_mapping := json_mapping == null or use_rpc_filesystem ? null : json.parse json_mapping

  uri_path_translator := UriPathTranslator uri_path_mapping

  in_pipe  := pipe.stdin
  out_pipe := pipe.stdout

  // Generally, this flag is not used, as the extension has a way to log
  // output anyway.
  should_log := false
  if should_log:
    time := Time.now.stringify
    log_in_file := file.Stream "/tmp/lsp_in-$(time).log" file.CREAT | file.WRONLY 0x1ff
    log_out_file := file.Stream "/tmp/lsp_out-$(time).log" file.CREAT | file.WRONLY 0x1ff
    //log_in_file  := file.Stream "/tmp/lsp.log" file.CREAT | file.WRONLY 0x1ff
    //log_out_file := log_in_file
    in_pipe  = LoggingIO log_in_file  in_pipe
    out_pipe = LoggingIO log_out_file out_pipe

  reader := BufferedReader in_pipe
  writer := out_pipe

  rpc_connection := RpcConnection reader writer

  server := LspServer rpc_connection toit_path_override uri_path_translator
      --use_rpc_filesystem=use_rpc_filesystem
      --rpc_sdk_path_placeholder=rpc_sdk_path_placeholder
  server.run
