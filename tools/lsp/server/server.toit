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
import host.file
import host.directory
import host.pipe
import io

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
import .uri-path-translator as translator
import .utils
import .verbose

DEFAULT-SETTINGS /Map ::= {:}
DEFAULT-TIMEOUT-MS ::= 10_000
DEFAULT-REPRO-DIR ::= "/tmp/lsp_repros"
CRASH-REPORT-RATE-LIMIT-MS ::= 30_000

/**
The settings for this server.

This class is a monitor so that the $replace function blocks other method accesses
  until the replacement is done.
*/
monitor Settings:
  map_ /Map := DEFAULT-SETTINGS

  get_ key [--if-absent]:
    return map_.get key --if-absent=if-absent

  // While the new values are fetched, all other requests to the settings are blocked.
  replace [b] -> none:
    replacement-map := b.call map_
    // The client is allowed to return `null` if it doesn't have
    // any configuration for the settings we requested.
    if replacement-map: map_ = replacement-map

  replace new-map/Map -> none: map_ = new-map

  is-verbose -> bool:
    return (get_ "verbose" --if-absent=: false) == true

  repro-dir -> string:
    return get_ "reproDir" --if-absent=: DEFAULT-REPRO-DIR

  toit-compiler-path -> string:
    return get_ "toitPath" --if-absent=: "toit.compile"

  sdk-path compiler-path/string -> string:
    return get_ "sdkPath" --if-absent=: sdk-path-from-compiler compiler-path

  timeout-ms -> int:
    return get_ "timeoutMs" --if-absent=: DEFAULT-TIMEOUT-MS

  should-write-repro -> bool:
    return (get_ "shouldWriteReproOnCrash" --if-absent=: false) == true

  should-report-package-diagnostics -> bool:
    return (get_ "reportPackageDiagnostics" --if-absent=: false) == true

class LspServer:
  documents_     /Documents         ::= Documents
  connection_    /RpcConnection     ::= ?
  toit-path-override_  /string?     ::= ?
  /// The root uri of the workspace.
  /// Rarely needed, as the server generally works with absolute paths.
  root-uri_ /string? := null

  active-requests_ := 0
  on-idle-callbacks_ := []

  next-analysis-revision_ := 0

  client-supports-configuration_ := false
  client-supports-completion-range_ := false

  /// The settings from the client (or, if not supported, default settings).
  settings_ /Settings := Settings

  last-crash-report-time_ := null

  /// A set of open request-ids
  /// When a request is canceled, it is removed from the set, so
  ///   that we don't respond multiple times.
  open-requests_ /Set := {}

  constructor .connection_ .toit-path-override_:

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
        "toit/reportIdle":         (:: report-idle),
        "toit/resetCrashRateLimit": (:: reset-crash-rate-limit),
        "toit/settings":           (:: settings_.map_),
        "toit/analyzeMany":        (:: analyze-many it),
        "toit/archive":            (:: archive (ArchiveParams it)),
        "toit/snapshotBundle":     (:: snapshot-bundle (SnapshotBundleParams it))
    }
    handlers.get method --if-present=: return it.call params

    verbose: "Unknown/unimplemented method $method"
    return ResponseError
        --code=ErrorCodes.method-not-found
        --message="Unknown or unimplemented method $method"

  set-sdk-path sdk-path/string -> none:
    settings_.replace: | old/Map |
      new := old.copy
      new["sdkPath"] = sdk-path
      new

  set-toitc toitc-path/string -> none:
    settings_.replace: | old/Map |
      new := old.copy
      new["toitPath"] = toitc-path
      new

  set-timeout-ms timeout-ms/int -> none:
    settings_.replace: | old/Map |
      new := old.copy
      new["timeoutMs"] = timeout-ms
      new

  /**
  Initializes the server with the client-information and responds with
    the server capabilities.
  */
  initialize params/InitializeParams -> InitializationResult:
    capabilities := params.capabilities
    client-supports-configuration_ = capabilities.workspace != null and capabilities.workspace.configuration
    client-supports-completion-range_ = capabilities.text-document and
        capabilities.text-document.completion and
        capabilities.text-document.completion.completion-list and
        capabilities.text-document.completion.completion-list.item-defaults and
        capabilities.text-document.completion.completion-list.item-defaults.contains "editRange"
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
      is-verbose = is-verbose or settings_.is-verbose
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
    uri := translator.canonicalize document.uri
    project-uri := documents_.project-uri-for --uri=uri
    // We are calling `analyze` just after updating the document.
    // The next analysis-revision is thus the one where the new content has been
    //   taken into account.
    content-revision := next-analysis-revision_
    documents_.did-open --uri=uri document.text content-revision
    analyze [uri]

  analyze-many params -> none:
    uris := params["uris"]
    uris = uris.map: translator.canonicalize it
    analyze uris

  archive params/ArchiveParams -> string:
    non-canonicalized-uris := params.uris or [params.uri]
    // If the request doesn't specify whether it wants the sdk we include it.
    include-sdk := params.include-sdk == null ? true : params.include-sdk
    uris := non-canonicalized-uris.map: translator.canonicalize it
    // We assume the project-uri is from the first uri.
    project-uri := documents_.project-uri-for --uri=uris[0]
    paths := uris.map: translator.to-path it
    compiler := compiler_
    compiler.parse --paths=paths --project-uri=project-uri
    buffer := io.Buffer
    write-repro
        --writer=buffer
        --compiler-flags=compiler.build-run-flags --project-uri=project-uri
        --compiler-input=json.stringify paths
        --protocol=compiler.protocol
        --info="toit/archive"
        --cwd-path=null
        --include-sdk=include-sdk
    byte-array := buffer.bytes
    return base64.encode byte-array

  snapshot-bundle params/SnapshotBundleParams -> Map?:
    uri := translator.canonicalize params.uri
    project-uri := documents_.project-uri-for --uri=uri
    compiler := compiler_
    bundle := compiler.snapshot-bundle --project-uri=project-uri uri
    // Encode the byte-array as base64.
    if not bundle: return null
    return {
      "snapshot_bundle": base64.encode bundle
    }

  did-close params/DidCloseTextDocumentParams -> none:
    uri := translator.canonicalize params.text-document.uri
    documents_.did-close --uri=uri
    if not settings_.should-report-package-diagnostics and is-inside-dot-packages --uri=uri:
      // Emit an empty diagnostics for this file, in case it had diagnostics before.
      send-diagnostics (PushDiagnosticsParams --uri=uri --diagnostics=[])

  did-save params/DidSaveTextDocumentParams -> none:
    uri := translator.canonicalize params.text-document.uri
    // No need to validate, since we should have gotten a `did_change` before
    //   any save (if the document was dirty).
    documents_.did-save --uri=uri

  did-change params/DidChangeTextDocumentParams -> none:
    document := params.text-document
    changes  := params.content-changes
    uri := translator.canonicalize document.uri
    changes.do:
      assert: it.range == null  // We only support full-file updates for now.
      // We are calling `analyze` just after updating the document.
      // The next analysis-revision is thus the one where the new content has been
      //   taken into account.
      documents_.did-change --uri=uri it.text next-analysis-revision_
    analyze [uri]

  completion params/CompletionParams -> any: // Either a List/*<CompletionItem>*/ or a $CompletionList.
    uri := translator.canonicalize params.text-document.uri
    project-uri := documents_.project-uri-for --uri=uri --recompute
    compiler_.complete --project-uri=project-uri uri params.position.line params.position.character:
      | prefix/string edit-range/Range? completions/List |
      if completions.is-empty: return completions
      if not prefix.ends-with "-": return completions
      // The prefix ends with a '-'. VS Code doesn't like that and assumes that any completion we
      // give is a new word. We therefore either adda default-range, or run through all
      // completions and add a textEdit.
      // TODO(florian): completion-range feature is disabled until we can test it on a
      // real editor. When changing, make sure to update the test and the Go version.
      if false and client-supports-completion-range_:
        return CompletionList
            --items=completions
            --item-defaults=(CompletionItemDefaults --edit-range=edit-range)
      completions.do: | item/CompletionItem |
        text-edit := TextEdit --range=edit-range --new-text=item.label
        item.set-text-edit text-edit
      return completions
    unreachable

  // TODO(florian): The specification supports a list of locations, or Locationlinks..
  // For now just returns one location.
  goto-definition params/TextDocumentPositionParams -> List/*<Location>*/:
    uri := translator.canonicalize params.text-document.uri
    project-uri := documents_.project-uri-for --uri=uri --recompute
    return compiler_.goto-definition --project-uri=project-uri uri params.position.line params.position.character

  document-symbol params/DocumentSymbolParams -> List/*<DocumentSymbol>*/:
    uri := translator.canonicalize params.text-document.uri
    project-uri := documents_.project-uri-for --uri=uri --recompute
    analyzed-documents := documents_.analyzed-documents-for --project-uri=project-uri
    document := analyzed-documents.get --uri=uri
    if not (document and document.summary):
      analyze --project-uri=project-uri [uri] next-analysis-revision_++
      document = analyzed-documents.get-existing --uri=uri
      if not document.summary: return []
    opened-document := documents_.get-opened --uri=uri
    content := ""
    if opened-document:
      content = opened-document.content
    else:
      path := translator.to-path uri
      if file.is-file path:
        content = (file.read-content path).to-string
    if not content: return []
    return document.summary.to-lsp-document-symbol content

  semantic-tokens params/SemanticTokensParams -> SemanticTokens:
    uri := translator.canonicalize params.text-document.uri
    project-uri := documents_.project-uri-for --uri=uri --recompute
    tokens := compiler_.semantic-tokens --project-uri=project-uri uri
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

    project-uris := {:}
    uris.do: |uri|
      project-uri := documents_.project-uri-for --uri=uri --recompute
      list := project-uris.get project-uri --init=:[]
      list.add uri

    changed-summary-documents := {}
    while true:
      old-changed-size := changed-summary-documents.size
      project-uris.do: |project-uri uris|
        changed-in-project := analyze uris --project-uri=project-uri revision
        changed-summary-documents.add-all changed-in-project
      if changed-summary-documents.size == old-changed-size: break
      // Do another run for changed summaries in other projects.
      project-uris.clear
      changed-summary-documents.do: | uri |
        project-uris-for-uri := documents_.project-uris-containing --uri=uri
        project-uris-for-uri.do: |document-project-uri|
          // No need to analyze, if that already happened.
          analyzed-documents := documents_.analyzed-documents-for --project-uri=document-project-uri
          document := analyzed-documents.get-existing --uri=uri
          if document.analysis-revision < revision:
            list := project-uris.get document-project-uri --init=:[]
            list.add uri

  analyze uris/List --project-uri/string? revision/int -> Set:
    analyzed-documents := documents_.analyzed-documents-for --project-uri=project-uri

    assert:
      uris.every: | uri |
        doc := analyzed-documents.get --uri=uri
        not doc or doc.analysis-revision < revision

    verbose: "Analyzing: $uris  ($revision) in $project-uri"

    analysis-result := compiler_.analyze --project-uri=project-uri uris
    if not analysis-result:
      verbose: "Analysis failed (no analysis result). ($revision)"
      return {} // Analysis didn't succeed. Don't bother with the result.

    summaries := analysis-result.summaries
    diagnostics-per-uri := analysis-result.diagnostics
    // We can't send diagnostics without position to the client, but we can use it
    // to guess why a compilation failed.
    diagnostics-without-position := analysis-result.diagnostics-without-position

    if summaries == null:
      // If the diagnostics without position isn't empty, and contains something for a uri, we
      // assume that there was a problem reading the file.
      uris.do: |uri|
        entry-path := translator.to-path uri
        probably-entry-problem := diagnostics-per-uri.is-empty and
            diagnostics-without-position.any: it.contains entry-path
        if probably-entry-problem:
          document := documents_.get-opened --uri=uri
          if document:
            // This should not happen.
            // TODO(florian): report to client and log (potentially creating repro).
          if file.is-file entry-path:
            // TODO(florian): report to client and log (potentially creating repro).
          // Either way: delete the entry.
          documents_.delete --uri=uri
      // Don't use the analysis result.
      return {}

    // Documents for which the summary changed.
    changed-summary-documents := {}
    // Documents for which we want to report diagnostics.
    report-diagnostics-documents := {}

    // Always report diagnostics for the given uris, unless there is a more recent
    // analysis already, or if the document has been updated in the meantime.
    uris.do: | uri |
      doc := analyzed-documents.get-or-create --uri=uri
      opened-doc := documents_.get-opened --uri=uri
      content-revision := opened-doc ? opened-doc.revision : -1
      if not doc.analysis-revision >= revision and not content-revision > revision:
        report-diagnostics-documents.add uri

    summaries.do: |summary-uri summary|
      assert: summary != null
      opened := documents_.get-opened --uri=summary-uri
      content-revision := opened ? opened.revision : -1
      update-result := analyzed-documents.update-document-after-analysis
          --uri=summary-uri
          --analysis-revision=revision
          --content-revision=content-revision
          --summary=summary
      has-changed-summary := (update-result & AnalyzedDocuments.SUMMARY-CHANGED-EXTERNALLY-BIT) != 0
      first-analysis-after-content-change :=
          (update-result & AnalyzedDocuments.FIRST-ANALYSIS-AFTER-CONTENT-CHANGE-BIT) != 0

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
      dep-document := analyzed-documents.get-existing --uri=summary-uri
      request-revision := dep-document.analysis-requested-by-revision
      if request-revision != -1 and request-revision < revision:
        report-diagnostics-documents.add summary-uri

    // All reverse dependencies of changed documents need to have their diagnostics printed.
    changed-summary-documents.do:
      document := analyzed-documents.get-existing --uri=it

      // Local lambda that transitively adds reverse dependencies.
      // We add all transitive dependencies, as it's hard to track implicit exports.
      // For example, the return type of a method, requires all users of the method
      //   to check whether a member call of the result is now allowed or not.
      //   Say class 'A' in lib1 has a method 'foo' that is changed to take an additional parameter.
      //   Say lib2 imports lib1 and return an 'A' from its 'bar' method.
      //   Say lib3 imports lib2 and calls `bar.foo`. This call needs a diagnostic change, since
      //     the 'foo' method now requires an additional parameter.
      //
      // This can be happen multiple layers down.
      // Note that we do this only if the summary of the initial file changes. As such, we
      //   usually don't analyze everything.
      //
      // We will also remove files that are in a different project-root. During the
      //   reverse dependency creation we add them (so we don't end up in an infinite
      //   recursion), but they will be removed just afterwards.
      add-rev-deps := null
      add-rev-deps = :: |rev-dep-uri|
        if not report-diagnostics-documents.contains rev-dep-uri:
          report-diagnostics-documents.add rev-dep-uri
          rev-document := analyzed-documents.get-existing --uri=rev-dep-uri
          rev-document.reverse-deps.do: add-rev-deps.call it

      document.reverse-deps.do: add-rev-deps.call it

    // Remove the documents that are not in the same project-root, or are in
    // .packages (assuming we don't want them).
    should-report-package-diagnostics := settings_.should-report-package-diagnostics
    report-diagnostics-documents.filter --in-place: | uri/string |
      document-project-uri := documents_.project-uri-for --uri=uri
      if document-project-uri != project-uri: continue.filter false
      if not should-report-package-diagnostics and is-inside-dot-packages --uri=uri:
        // Only report diagnostics for package files if they are open.
        if not documents_.get-opened --uri=uri:
          continue.filter false
      true

    // Send the diagnostics we have to the client.
    report-diagnostics-documents.do: |uri|
      document := analyzed-documents.get-existing --uri=uri
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
      document := analyzed-documents.get-existing --uri=uri
      up-to-date := document.analysis-revision >= revision
      opened := documents_.get-opened --uri=uri
      content-revision := opened ? opened.revision : -1
      will-be-analyzed := content-revision > revision
      not up-to-date and not will-be-analyzed

    // See which documents need to be analyzed as a result of changes.
    documents-needing-analysis := report-diagnostics-documents.filter --in-place: // Reuse the set.
      needs-analysis.call it

    if not documents-needing-analysis.is-empty:
      // It's highly unlikely that a reverse dependency changes its summary as a result
      // of a change in a dependency. However, this can easily change with language
      // extensions. As such, we just add the result of the recursive call to our result.
      rev-dep-result := analyze (List.from documents-needing-analysis) revision --project-uri=project-uri
      changed-summary-documents.add-all rev-dep-result

    return changed-summary-documents

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
    repro-dir := settings_.repro-dir
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
    return toit-path-override_ or settings_.toit-compiler-path

  sdk-path_ -> string:
    // We can't access a setting while reading settings (the Setting class is a
    // monitor). Read the compiler_path first.
    compiler-path := compiler-path_
    return settings_.sdk-path compiler-path

  compiler_ -> Compiler:
    compiler-path := compiler-path_
    sdk-path := sdk-path_
    timeout-ms := settings_.timeout-ms

    // Rate limit crash reporting.
    is-rate-limited := false
    if last-crash-report-time_:
      current-us := Time.monotonic-us
      CRASH-LIMIT-US ::= CRASH-REPORT-RATE-LIMIT-MS * 1_000
      is-rate-limited = (Time.monotonic-us - last-crash-report-time_) <= CRASH-LIMIT-US

    should-write-repro := settings_.should-write-repro

    protocol := FileServerProtocol.local compiler-path sdk-path documents_

    compiler := null  // Let the 'compiler' local be visible in the lambda expression below.
    compiler = Compiler compiler-path timeout-ms
        --protocol=protocol
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
                --cwd-path=root-uri_ and (translator.to-path root-uri_)
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
          cli.Option "toit-path-override",
      ]
      --options=[
          cli.Flag "verbose" --default=false,
      ]
      --run=:: parsed = it
  parser.run args
  if not parsed: exit 0

  toit-path-override := parsed["toit-path-override"]

  is-verbose = parsed["verbose"] == true
  main --toit-path-override=toit-path-override

main --toit-path-override/string?:
  in-pipe  := pipe.stdin
  out-pipe := pipe.stdout

  // Generally, this flag is not used, as the extension has a way to log
  // output anyway.
  should-log := false
  reader/io.Reader := ?
  writer/io.Writer := ?
  if should-log:
    time := Time.now.stringify
    log-in-file := file.Stream "/tmp/lsp_in-$(time).log" file.CREAT | file.WRONLY 0x1ff
    log-out-file := file.Stream "/tmp/lsp_out-$(time).log" file.CREAT | file.WRONLY 0x1ff
    //log_in_file  := file.Stream "/tmp/lsp.log" file.CREAT | file.WRONLY 0x1ff
    //log_out_file := log_in_file
    reader = (LoggingIO log-in-file in-pipe).in
    writer = (LoggingIO log-out-file out-pipe).out
  else:
    reader = io.Reader.adapt in-pipe
    writer = io.Writer.adapt out-pipe

  rpc-connection := RpcConnection reader writer

  server := LspServer rpc-connection toit-path-override
  server.run

compute-summaries --uris/List --toitc/string --sdk-path -> Documents:
  sdk-uri := translator.to-uri sdk-path

  in-pipe := FakePipe
  out-pipe := FakePipe
  drain-task := task --background::
    // We are not interested in whatever the server tries to send.
    out-pipe.in.drain
  rpc-connection := RpcConnection in-pipe.in out-pipe.out

  server := LspServer rpc-connection toitc

  root-uri/string? := translator.to-uri directory.cwd
  initialize-params := InitializeParams --root-uri=root-uri --capabilities=(ClientCapabilities)
  server.initialize initialize-params
  server.initialized
  server.set-sdk-path sdk-path
  server.set-toitc toitc
  server.set-timeout-ms 0  // No timeout.

  server.analyze-many { "uris": uris }

  server.shutdown
  drain-task.cancel

  return server.documents_
