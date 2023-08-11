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
import .protocol.document-symbol
import .protocol.initialization
import .protocol.message
import .protocol.server-capabilities
import .protocol.semantic-tokens
import .protocol-toit

import .compiler
import .documents
import .file-server
import .repro
import .rpc
import .uri-path-translator
import .utils
import .verbose

DEFAULT-SETTINGS /Map ::= {:}
DEFAULT-TIMEOUT-MS ::= 10_000
DEFAULT-REPRO-DIR ::= "/tmp/lsp_repros"
CRASH-REPORT-RATE-LIMIT-MS ::= 30_000

monitor Settings:
  map_ /Map := DEFAULT-SETTINGS

  get key: return get key --if-absent=: null

  get key [--if-absent]:
    return map_.get key --if-absent=if-absent

  // While the new values are fetched, all other requests to the settings are blocked.
  replace [b] -> none:
    replacement-map := b.call
    // The client is allowed to return `null` if it doesn't have
    // any configuration for the settings we requested.
    if replacement-map: map_ = replacement-map

  replace new-map/Map -> none: map_ = new-map

class LspServer:
  documents_     /Documents         ::= ?
  connection_    /RpcConnection     ::= ?
  translator_    /UriPathTranslator ::= ?
  toit-path-override_  /string?     ::= ?
  /// The root uri of the workspace.
  /// Rarely needed, as the server generally works with absolute paths.
  /// It's mainly used to find package.lock files.
  root-uri_ /string? := null

  active-requests_ := 0
  on-idle-callbacks_ := []

  next-analysis-revision_ := 0

  client-supports-configuration_ := false
  /// The settings from the client (or, if not supported, default settings).
  settings_ /Settings := Settings

  last-crash-report-time_ := null

  /// A set of open request-ids
  /// When a request is canceled, it is removed from the set, so
  ///   that we don't respond multiple times.
  open-requests_ /Set := {}

  constructor
      .connection_
      .toit-path-override_
      .translator_:
    documents_ = Documents translator_

  run -> none:
    while true:
      parsed := connection_.read
      if parsed == null: return
      id := parsed.get "id"
      if id: open-requests_.add id
      task:: catch --trace:
        active-requests_++
        method := parsed["method"]
        params := parsed.get "params"
        verbose: "Request for $method $id"
        response := handle_ method params
        verbose: "Request $method $id handled"
        if id and (open-requests_.contains id):
          open-requests_.remove id
          connection_.reply id response
        active-requests_--
        if active-requests_ == 0 and not on-idle-callbacks_.is-empty:
          callbacks := on-idle-callbacks_
          on-idle-callbacks_ = []
          callbacks.do: it.call

  handle_ method/string params/Map? -> any:
    // TODO(florian): this should be a switch or something.
    handlers ::= {
        "initialize":              (:: initialize (InitializeParams it)),
        "initialized":             (:: initialized),
        "\$/cancelRequest":        (:: cancel     (CancelParams it)),
        "textDocument/didOpen":    (:: did-open   (DidOpenTextDocumentParams   it)),
        "textDocument/didChange":  (:: did-change (DidChangeTextDocumentParams it)),
        "textDocument/didSave":    (:: did-save   (DidSaveTextDocumentParams   it)),
        "textDocument/didClose":   (:: did-close  (DidCloseTextDocumentParams   it)),
        "textDocument/completion": (:: completion (CompletionParams it )),
        "textDocument/definition": (:: goto-definition (TextDocumentPositionParams it)),
        "textDocument/documentSymbol": (:: document-symbol (DocumentSymbolParams it)),
        "textDocument/semanticTokens/full": (:: semantic-tokens (SemanticTokensParams it)),
        "shutdown":                (:: shutdown),
        "exit":                    (:: exit),
        "toit/report_idle":        (:: report-idle),
        "toit/reset_crash_rate_limit": (:: reset-crash-rate-limit),
        "toit/settings":           (:: settings_.map_),
        "toit/didOpenMany":        (:: did-open-many it),
        "toit/archive":            (:: archive (ArchiveParams it)),
        "toit/snapshot_bundle":    (:: snapshot-bundle (SnapshotBundleParams it))
    }
    handlers.get method --if-present=: return it.call params

    verbose: "Unknown/unimplemented method $method"
    return ResponseError
        --code=ErrorCodes.method-not-found
        --message="Unknown or unimplemented method $method"

  /**
  Initializes the server with the client-information and responds with
    the server capabilities.
  */
  initialize params/InitializeParams -> InitializationResult:
    capabilities := params.capabilities
    client-supports-configuration_ = capabilities.workspace != null and capabilities.workspace.configuration
    root-uri_ = params.root-uri
    // Process experimental features, some implemented by us.
    if params.capabilities.experimental:
      if params.capabilities.experimental.ubjson-rpc: connection_.enable-ubjson

    server-capabilities := ServerCapabilities
        --completion-provider= CompletionOptions
            --resolve-provider=   false
            --trigger-characters= [".", "-", "\$"]
        --definition-provider=      true
        --document-symbol-provider= true
        --text-document-sync= TextDocumentSyncOptions
            --open-close
            --change= TextDocumentSyncKind.full
            --save=   SaveOptions --no-include-text
        --semantic-tokens-provider= SemanticTokensOptions
            --legend= SemanticTokensLegend
                --token-types= Compiler.SEMANTIC-TOKEN-TYPES
                --token-modifiers= Compiler.SEMANTIC-TOKEN-MODIFIERS
            --no-range
            --full= true  // Or should it be '{ "delta": false }' ?
        --experimental=Experimental --ubjson-rpc

    return InitializationResult server-capabilities

  initialized -> none:
    // Get the settings, in case the client supports configuration. (Otherwise they are already filled
    //   with default values).
    if client-supports-configuration_:
      settings_.replace: request-settings
      // Client configurations can only make the output verbose, but not disable it,
      //   if it was given by command-line.
      is-verbose = is-verbose or (settings_.get "verbose" --if-absent=: false) == true
    // TODO(florian): register DidChangeConfigurationNotification.type

  cancel params/CancelParams -> none:
    id := params.id
    task := open-requests_.get id
    if task:
      open-requests_.remove id
      connection_.reply id
          ResponseError
            --code=ErrorCodes.request-cancelled
            --message="Cancelled on request"

  did-open params/DidOpenTextDocumentParams -> none:
    document := params.text-document
    uri := translator_.canonicalize document.uri
    // We are calling `analyze` just after updating the document.
    // The next analysis-revision is thus the one where the new content has been
    //   taken into account.
    content-revision := next-analysis-revision_
    documents_.did-open --uri=uri document.text content-revision
    analyze [uri]

  did-open-many params -> none:
    uris := params["uris"]
    uris = uris.map: translator_.canonicalize it
    content-revision := next-analysis-revision_
    uris.do:
      content := null
      documents_.did-open --uri=it content content-revision
    analyze uris

  archive params/ArchiveParams -> string:
    non-canonicalized-uris := params.uris or [params.uri]
    // If the request doesn't specify whether it wants the sdk we include it.
    include-sdk := params.include-sdk == null ? true : params.include-sdk
    uris := non-canonicalized-uris.map: translator_.canonicalize it
    paths := uris.map: translator_.to-path it
    compiler := compiler_
    compiler.parse --paths=paths
    buffer := bytes.Buffer
    write-repro
        --writer=buffer
        --compiler-flags=compiler.build-run-flags
        --compiler-input=json.stringify paths
        --protocol=compiler.protocol
        --info="toit/archive"
        --cwd-path=null
        --include-sdk=include-sdk
    byte-array := buffer.bytes
    return base64.encode byte-array

  snapshot-bundle params/SnapshotBundleParams -> Map?:
    uri := translator_.canonicalize params.uri
    compiler := compiler_
    bundle := compiler.snapshot-bundle uri
    // Encode the byte-array as base64.
    if not bundle: return null
    return {
      "snapshot_bundle": base64.encode bundle
    }

  did-close params/DidCloseTextDocumentParams -> none:
    uri := translator_.canonicalize params.text-document.uri
    documents_.did-close --uri=uri

  did-save params/DidSaveTextDocumentParams -> none:
    uri := translator_.canonicalize params.text-document.uri
    // No need to validate, since we should have gotten a `did_change` before
    //   any save (if the document was dirty).
    documents_.did-save --uri=uri

  did-change params/DidChangeTextDocumentParams -> none:
    document := params.text-document
    changes  := params.content-changes
    uri := translator_.canonicalize document.uri
    changes.do:
      assert: it.range == null  // We only support full-file updates for now.
      // We are calling `analyze` just after updating the document.
      // The next analysis-revision is thus the one where the new content has been
      //   taken into account.
      documents_.did-change --uri=uri it.text next-analysis-revision_
    analyze [uri]

  completion params/CompletionParams -> List/*<CompletionItem>*/:
    uri := translator_.canonicalize params.text-document.uri
    return compiler_.complete uri params.position.line params.position.character

  // TODO(florian): The specification supports a list of locations, or Locationlinks..
  // For now just returns one location.
  goto-definition params/TextDocumentPositionParams -> List/*<Location>*/:
    uri := translator_.canonicalize params.text-document.uri
    return compiler_.goto-definition uri params.position.line params.position.character

  document-symbol params/DocumentSymbolParams -> List/*<DocumentSymbol>*/:
    uri := translator_.canonicalize params.text-document.uri
    document := documents_.get --uri=uri
    if not (document and document.summary):
      analyze [uri]
      document = documents_.get-existing-document --uri=uri
      if not document.summary: return []
    content := ""
    if document.content:
      content = document.content
    else:
      path := translator_.to-path uri
      if file.is-file path:
        content = (file.read-content path).to-string
    if not content: return []
    return document.summary.to-lsp-document-symbol content

  semantic-tokens params/SemanticTokensParams -> SemanticTokens:
    uri := translator_.canonicalize params.text-document.uri
    tokens := compiler_.semantic-tokens uri
    return SemanticTokens --data=tokens

  shutdown:
    // Do nothing yet.
    return null

  exit:
    on-idle-callbacks_.add (:: core.exit 0)
    task:: catch --trace:
      // Force an exit in case some request is not terminating.
      sleep --ms=1000
      core.exit 1

  report-idle:
    on-idle-callbacks_.add (:: connection_.send "toit/idle" null)

  /**
  Analyzes the given $uris and sends diagnostics to the client.

  Transitively analyzes all newly discovered files.
  */
  analyze uris/List revision/int?=null -> none:
    if uris.is-empty: return

    revision = revision or next-analysis-revision_++
    assert: uris.every: | uri |
      (documents_.get-existing-document --uri=uri).analysis-revision < revision

    verbose: "Analyzing: $uris  ($revision)"

    analysis-result := compiler_.analyze uris
    if not analysis-result:
      verbose: "Analysis failed (no analysis result). ($revision)"
      return  // Analysis didn't succeed. Don't bother with the result.

    summaries := analysis-result.summaries
    diagnostics-per-uri := analysis-result.diagnostics
    // We can't send diagnostics without position to the client, but we can use it
    // to guess why a compilation failed.
    diagnostics-without-position := analysis-result.diagnostics-without-position

    if summaries == null:
      // If the diagnostics without position isn't empty, and contains something for a uri, we
      // assume that there was a problem reading the file.
      uris.do: |uri|
        entry-path := translator_.to-path uri
        probably-entry-problem := diagnostics-per-uri.is-empty and
            diagnostics-without-position.any: it.contains entry-path
        document := documents_.get --uri=uri
        if probably-entry-problem and document:
          if document.is-open:
            // This should not happen.
            // TODO(florian): report to client and log (potentially creating repro).
          else:
            if file.is-file entry-path:
              // TODO(florian): report to client and log (potentially creating repro).
            // Either way: delete the entry.
            documents_.delete --uri=uri
      // Don't use the analysis result.
      return

    // Documents for which the summary changed.
    changed-summary-documents := {}
    // Documents for which we want to report diagnostics.
    report-diagnostics-documents := {}

    // Always report diagnostics for the given uris, unless there is a more recent
    // analysis already, or if the document has been updated in the meantime.
    uris.do: | uri |
      doc := documents_.get-existing-document --uri=uri
      if not doc.analysis-revision >= revision and not doc.content-revision > revision:
        report-diagnostics-documents.add uri

    summaries.do: |summary-uri summary|
      assert: summary != null
      update-result := documents_.update-document-after-analysis --uri=summary-uri
          --analysis-revision=revision
          --summary=summary
      has-changed-summary := (update-result & Documents.SUMMARY-CHANGED-EXTERNALLY-BIT) != 0
      first-analysis-after-content-change :=
          (update-result & Documents.FIRST-ANALYSIS-AFTER-CONTENT-CHANGE-BIT) != 0

      // If the summary has changed, it either means that:
      //  - this was one of the $uris that was analyzed
      //  - the $summary_uri depends on one of the $uris (but was also reachable from them)
      //  - the $summary_uri (or one of its dependencies) was changed. This could be because
      //    of a change on disk, or because of a `did_change` call. In the latter case,
      //    there would still be another analysis running, but this one completed earlier.
      if has-changed-summary:
        changed-summary-documents.add summary-uri
      if has-changed-summary or first-analysis-after-content-change:
        report-diagnostics-documents.add summary-uri
      dep-document := documents_.get-existing-document --uri=summary-uri
      request-revision := dep-document.analysis-requested-by-revision
      if request-revision != -1 and request-revision < revision:
        report-diagnostics-documents.add summary-uri

    // All reverse dependencies of changed documents need to have their diagnostics printed.
    changed-summary-documents.do:
      document := documents_.get-existing-document --uri=it

      // Local lambda that transitively adds reverse dependencies.
      // We add all transitive dependencies, as it's hard to track implicit exports.
      // For example, the return type of a method, requires all users of the method
      //   to check whether a member call of the result is now allowed or not.
      // This can be happen multiple layers down. See #1513 for an example.
      // Note that we do this only if the summary of the initial file changes. As such, we
      //   usually don't analyze everything.
      add-rev-deps := null
      add-rev-deps = :: |rev-dep-uri|
        if not report-diagnostics-documents.contains rev-dep-uri:
          report-diagnostics-documents.add rev-dep-uri
          rev-document := documents_.get-existing-document --uri=rev-dep-uri
          rev-document.reverse-deps.do: add-rev-deps.call it

      document.reverse-deps.do: add-rev-deps.call it

    // Send the diagnostics we have to the client.
    report-diagnostics-documents.do: |uri|
      document := documents_.get-existing-document --uri=uri
      request-revision := document.analysis-requested-by-revision
      was-analyzed := summaries.contains uri
      if was-analyzed:
        diagnostics := diagnostics-per-uri.get uri --if-absent=: []
        send-diagnostics (PushDiagnosticsParams --uri=uri --diagnostics=diagnostics)
        if request-revision != -1 and request-revision < revision:
          // Mark the request as done.
          document.analysis-requested-by-revision = -1
      else if request-revision < revision:
        document.analysis-requested-by-revision = revision

    // Local lambda that returns whether a document needs analysis.
    needs-analysis := : |uri|
      document := documents_.get-existing-document --uri=uri
      up-to-date := document.analysis-revision >= revision
      will-be-analyzed := document.content-revision and document.content-revision > revision
      not up-to-date and not will-be-analyzed

    // See which documents need to be analyzed as a result of changes.
    documents-needing-analysis := report-diagnostics-documents.filter --in-place: // Reuse the set
      needs-analysis.call it

    if not documents-needing-analysis.is-empty:
      analyze (List.from documents-needing-analysis) revision

  send-diagnostics params/PushDiagnosticsParams -> none:
    connection_.send "textDocument/publishDiagnostics" params

  request-settings -> Map?:
    params := ConfigurationParams --items= [ConfigurationItem --section="toitLanguageServer"]
    configuration := connection_.request "workspace/configuration" params
    // If the client doesn't have the the requested section, the content of the
    // configuration might be `null`.
    return configuration[0]  // We only requested one configuration, but it still comes in a list.

  send-log-message msg/string -> none:
    connection_.send "window/logMessage" {"type": 4, "message": msg}

  send-show-message msg -> none:
    connection_.send "window/showMessage" {"type": 3, "message": msg}

  static repro-counter_ := 0
  compute-repro-path_ -> string:
    repro-dir := settings_.get "reproDir" --if-absent=: DEFAULT-REPRO-DIR
    repro-prefix := "$repro-dir/repro"
    if not file.is-directory repro-dir:
      if file.is-file repro-dir:
        send-show-message "Repro-dir exists and is not a directory: $repro-dir"
        // Don't overwrite the existing file.
        // We have a loop just below to find the name of the next non-existing path.
        repro-prefix = "/tmp/lsp_repro"
      else:
        directory.mkdir repro-dir
    repro-path := ""
    while true:
      repro-path = "$(repro-prefix)_$(Time.monotonic-us)-$(repro-counter_++).tar"
      if not (file.is-file repro-path or file.is-directory repro-path): break
    return repro-path

  reset-crash-rate-limit: last-crash-report-time_ = null

  compiler-path_ -> string:
    compiler-path := toit-path-override_
    if compiler-path != null:
      return compiler-path
    return settings_.get "toitPath" --if-absent=: "toit.compile"

  sdk-path_ -> string:
    // We can't access a setting while reading settings (the Setting class is a
    // monitor). Read the compiler_path first.
    compiler-path := compiler-path_
    return settings_.get "sdkPath" --if-absent=:
      sdk-path-from-compiler compiler-path

  compiler_ -> Compiler:
    compiler-path := compiler-path_
    sdk-path := sdk-path_
    timeout-ms := settings_.get "timeoutMs" --if-absent=: DEFAULT-TIMEOUT-MS

    // Rate limit crash reporting.
    is-rate-limited := false
    if last-crash-report-time_:
      current-us := Time.monotonic-us
      CRASH-LIMIT-US ::= CRASH-REPORT-RATE-LIMIT-MS * 1_000
      is-rate-limited = (Time.monotonic-us - last-crash-report-time_) <= CRASH-LIMIT-US

    should-write-repro := settings_.get "shouldWriteReproOnCrash" --if-absent=:false

    protocol := FileServerProtocol.local compiler-path sdk-path documents_ translator_

    compiler := null  // Let the 'compiler' local be visible in the lambda expression below.
    compiler = Compiler compiler-path translator_ timeout-ms
        --protocol=protocol
        --project-uri=root-uri_
        --on-error=:: |message|
          if is-rate-limited:
            // Do nothing
          else if should-write-repro:
            // We are using the same flag to send a more visible message.
            send-show-message message
          else:
            send-log-message message
        --on-crash=:: |compiler-flags compiler-input signal protocol|
          if is-rate-limited:
            // Do nothing.
          else if should-write-repro:
            repro-path := compute-repro-path_
            write-repro
                --repro-path=repro-path
                --compiler-flags=compiler-flags
                --compiler-input=compiler-input
                --info=signal
                --protocol=protocol
                --cwd-path=root-uri_ and (translator_.to-path root-uri_)
                --include-sdk
            send-show-message "Compiler crashed. Repro created: $repro-path"
          else:
            send-log-message "Compiler crashed with signal $signal"
          last-crash-report-time_ = Time.monotonic-us
    return compiler

main args -> none:
  parsed := null
  parser := cli.Command "server"
      --rest=[
          cli.OptionString "toit-path-override",
      ]
      --options=[
          cli.OptionString "home-path",
          cli.Flag "verbose" --default=false,
      ]
      --run=:: parsed = it
  parser.run args
  if not parsed: exit 0

  toit-path-override := parsed["toit-path-override"]

  is-verbose = parsed["verbose"]

  uri-path-translator := UriPathTranslator

  in-pipe  := pipe.stdin
  out-pipe := pipe.stdout

  // Generally, this flag is not used, as the extension has a way to log
  // output anyway.
  should-log := false
  if should-log:
    time := Time.now.stringify
    log-in-file := file.Stream "/tmp/lsp_in-$(time).log" file.CREAT | file.WRONLY 0x1ff
    log-out-file := file.Stream "/tmp/lsp_out-$(time).log" file.CREAT | file.WRONLY 0x1ff
    //log_in_file  := file.Stream "/tmp/lsp.log" file.CREAT | file.WRONLY 0x1ff
    //log_out_file := log_in_file
    in-pipe  = LoggingIO log-in-file  in-pipe
    out-pipe = LoggingIO log-out-file out-pipe

  reader := BufferedReader in-pipe
  writer := out-pipe

  rpc-connection := RpcConnection reader writer

  server := LspServer rpc-connection toit-path-override uri-path-translator
  server.run
