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

import host.pipe
import host.file
import monitor
import reader show BufferedReader
import writer show Writer
import bytes

import .protocol.completion
import .protocol.document
import .protocol.diagnostic
import .file-server
import .summary show SummaryReader
import .uri-path-translator
import .utils
import .verbose
import .multiplex

class AnalysisResult:
  diagnostics / Map/*<uri/string, Diagnostics>*/ ::= ?
  diagnostics-without-position / List/*<string>*/ ::= ?
  summaries / Map?/*<uri/string, Module>*/ ::= ?

  constructor .diagnostics .diagnostics-without-position .summaries:

class Compiler:
  compiler-path_       /string             ::= ?
  uri-path-translator_ /UriPathTranslator  ::= ?
  on-crash_            /Lambda?     ::= ?
  on-error_            /Lambda?     ::= ?
  timeout-ms_          /int         ::= ?
  protocol             /FileServerProtocol ::= ?
  project-uri_         /string?     ::= ?

  constructor
      .compiler-path_
      .uri-path-translator_
      .timeout-ms_
      --.protocol
      --project-uri/string?
      --on-error/Lambda?=null
      --on-crash/Lambda?=null:
    on-crash_ = on-crash
    on-error_ = on-error
    project-uri_ = project-uri

  /**
  Builds the flags that are passed to the compiler.
  */
  build-run-flags -> List:
    args := [
      "--lsp",
    ]
    if project-uri_:
      project-path-local := uri-path-translator_.to-path project-uri_
      package-lock := "$project-path-local/package.lock"
      if file.is-file package-lock:
        project-path-compiler := uri-path-translator_.to-path project-uri_ --to-compiler
        args += ["--project-root", project-path-compiler]
    return args

  /**
  Starts the compiler and calls the given [write_callback]/[read_callback] with the opened pipes.

  Returns whether the call was successful.
  If there was a crash, invokes the stored `on_crash` handler, and returns false.
  */
  run --ignore-crashes/bool=false --compiler-input/string [read-callback] -> bool:
    flags := build-run-flags

    cpp-pipes := pipe.fork
        true                // use_path
        pipe.PIPE-CREATED   // stdin
        pipe.PIPE-CREATED   // stdout
        pipe.PIPE-INHERITED // stderr
        compiler-path_
        [compiler-path_] + flags
    cpp-to   := cpp-pipes[0]
    cpp-from := cpp-pipes[1]
    cpp-pid  := cpp-pipes[3]


    has-terminated := false
    was-killed-because-of-timeout := false

    multiplex := MultiplexConnection cpp-from
    multiplex.start-dispatch
    to-parser := multiplex.compiler-to-parser
    file-server := PipeFileServer protocol cpp-to multiplex.compiler-to-fs
    file-server-line := file-server.run

    if timeout-ms_ > 0:
      task:: catch --trace:
        sleep --ms=timeout-ms_
        if not has-terminated:
          SIGKILL ::= 9
          pipe.kill_ cpp-pid SIGKILL
          was-killed-because-of-timeout = true

    did-crash := false
    try:
      writer := Writer cpp-to
      writer.write "$file-server-line\n"
      writer.write compiler-input

      reader := BufferedReader to-parser
      read-callback.call reader
    finally:
      file-server.close
      to-parser.close
      multiplex.close

      exit-value := pipe.wait-for cpp-pid
      verbose: "Compiler terminated with exit_signal: $(pipe.exit-signal exit-value)"
      has-terminated = true
      if not ignore-crashes:
        exit-signal := pipe.exit-signal exit-value
        if exit-signal:
          // Assume that any exit-signal was because of a crash of the compiler.
          if on-crash_:
            reason := (pipe.signal-to-string exit-signal)
            if was-killed-because-of-timeout: reason += "\nKilled after timeout"
            on-crash_.call flags compiler-input reason file-server.protocol
          did-crash = true
    return not did-crash

  analyze uris/List -> AnalysisResult?:
    // Work around small stack size.
    // TODO(1268): remove work-around
    latch := monitor.Latch
    task:: catch --trace:
      paths := uris.map: | uri |
        path := uri-path-translator_.to-path uri --to-compiler
        // There are multiple ways to encode URIs. Check that the uri is already
        // canonicalized.
        assert: uri == (uri-path-translator_.to-uri path --from-compiler)
        path
      result := null

      verbose: "Calling compiler analysis with $paths"
      compiler-input := "ANALYZE\n$(paths.size)\n$(paths.join "\n")\n"
      completed-successfully := run --compiler-input=compiler-input:
        |reader /BufferedReader|

        summary := null

        diagnostics-per-uri := Map
        diagnostics-without-position := []

        in-group := false
        group-uri := null
        group-diagnostic := null
        related-information := null
        while true:
          line := reader.read-line
          if line == null: break
          if line == "": continue  // Empty lines are allowed.
          if line == "SUMMARY":
            assert: summary == null
            summary = read-summary reader
          else if line == "START GROUP":
            assert: not in-group
            assert: group-diagnostic == null
            assert: related-information == null
            in-group = true
          else if line == "END GROUP":
            group-diagnostic.related-information = related-information
            (diagnostics-per-uri.get group-uri --init=(: [])).add group-diagnostic
            in-group = false
            group-uri = null
            group-diagnostic = null
            related-information = null
          else if line == "WITH POSITION" or line == "NO POSITION":
            with-position := line == "WITH POSITION"
            severity := reader.read-line
            error-path := null
            error-uri := null
            range := null
            if with-position:
              error-path = reader.read-line
              error-uri = uri-path-translator_.to-uri error-path --from-compiler
              range = read-range reader
            msg-lines := []
            while true:
              line = reader.read-line
              if line == "*******************": break
              msg-lines.add line
            msg := msg-lines.join "\n"

            diagnostic-severity := ?
            if severity == "error":
              diagnostic-severity = DiagnosticSeverity.error
            else if severity == "warning":
              diagnostic-severity = DiagnosticSeverity.warning
            else:
              assert: severity == "information"
              diagnostic-severity = DiagnosticSeverity.information
            if not with-position:
              verbose: "Diagnostic without position: $msg"
              diagnostics-without-position.add msg
            else if not in-group:
              verbose: "Diagnostic for $error-uri: $msg"
              (diagnostics-per-uri.get error-uri --init=(: [])).add
                  Diagnostic
                    --range=    range
                    --message=  msg
                    --severity= diagnostic-severity
            else:
              if group-uri == null:
                verbose: "Starting group diagnostic for $error-uri: $msg"
                group-uri = error-uri
                group-diagnostic = Diagnostic
                    --range=    range
                    --message=  msg
                    --severity= diagnostic-severity
                related-information = []
              else:
                related-information.add
                    DiagnosticRelatedInformation
                        --location= Location
                            --uri=   error-uri
                            --range= range
                        --message=msg
          else:
            // Just ignore the message for now.
            if on-error_: on-error_.call "LSP Server: unexpected line from compiler: $line"
          result = AnalysisResult diagnostics-per-uri diagnostics-without-position summary
      latch.set (completed-successfully ? result : null)
    return latch.get

  complete uri/string line-number/int column-number/int -> List/*<string>*/:
    path := uri-path-translator_.to-path uri --to-compiler
    // We don't care if the compiler crashed.
    // Just send whatever completions we get.
    run --compiler-input="COMPLETE\n$path\n$line-number\n$column-number\n":
      |reader /BufferedReader|
      suggestions := []

      while true:
        line := reader.read-line
        if line == null: break
        kind := int.parse reader.read-line
        suggestions.add (CompletionItem --label=line --kind=kind)
      return suggestions
    unreachable

  goto-definition uri/string line-number/int column-number/int -> List/*<Location>*/:
    path := uri-path-translator_.to-path uri --to-compiler
    // We don't care if the compiler crashed.
    // Just send the definitions we got.
    run --compiler-input="GOTO DEFINITION\n$path\n$line-number\n$column-number\n":
      |reader /BufferedReader|
      definitions := []

      while true:
        line := reader.read-line
        if line == null: break
        location := Location
          --uri= uri-path-translator_.to-uri line --from-compiler
          --range= read-range reader
        definitions.add location

      return definitions
    unreachable

  parse --paths/List/*<string>*/ -> bool:
    // Parse all files and fill the fileserver.
    return run --compiler-input="PARSE\n$paths.size\n$(paths.join "\n")\n":
      |reader /BufferedReader|
      while true:
        // Just drain the reader.
        data := reader.read
        if not data: break

  snapshot-bundle uri/string -> ByteArray?:
    path := uri-path-translator_.to-path uri --to-compiler
    run --compiler-input="SNAPSHOT BUNDLE\n$path\n":
      |reader /BufferedReader|
      status := reader.read-line
      if status != "OK": return null
      bundle-size := int.parse reader.read-line
      buffer := bytes.Buffer
      buffer.reserve bundle-size
      while data := reader.read:
        buffer.write data
      if buffer.size != bundle-size: return null
      return buffer.bytes
    unreachable

  static SEMANTIC-TOKEN-TYPES ::= [
    "namespace",
    "class",
    "interface",
    "parameter",
    "variable",
  ]
  static SEMANTIC-TOKEN-MODIFIERS ::= [
    "definition",
    "readonly",
    "static",
    "abstract",
    "defaultLibrary",
  ]

  semantic-tokens uri/string -> List:
    path := uri-path-translator_.to-path uri --to-compiler
    run --compiler-input="SEMANTIC TOKENS\n$path\n":
      |reader /BufferedReader|
      element-count := int.parse reader.read-line
      result := List element-count: int.parse reader.read-line
      return result
    unreachable

  static read-range reader/BufferedReader -> Range:
    from-line-number := int.parse reader.read-line
    from-column-number := int.parse reader.read-line
    to-line-number := int.parse reader.read-line
    to-column-number := int.parse reader.read-line
    return Range
        Position from-line-number from-column-number
        Position to-line-number   to-column-number

  read-dependencies reader/BufferedReader -> Map/*<string, Set<string>>*/:
    entry-count := int.parse reader.read-line
    result := {:}
    entry-count.repeat:
      source-uri := uri-path-translator_.to-uri reader.read-line --from-compiler
      direct-deps-count := int.parse reader.read-line
      direct-deps := {}
      direct-deps-count.repeat:
        direct-deps.add (uri-path-translator_.to-uri reader.read-line --from-compiler)
      result[source-uri] = direct-deps

    return result

  read-summary reader/BufferedReader -> Map/*<path, Module>*/:
    return (SummaryReader reader uri-path-translator_).read-summary
