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
import io
import monitor

import .protocol.completion
import .protocol.document
import .protocol.diagnostic
import .file-server
import .summary show SummaryReader
import .uri-path-translator as translator
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
  on-crash_            /Lambda?     ::= ?
  on-error_            /Lambda?     ::= ?
  timeout-ms_          /int         ::= ?
  protocol             /FileServerProtocol ::= ?

  constructor
      .compiler-path_
      .timeout-ms_
      --.protocol
      --on-error/Lambda?=null
      --on-crash/Lambda?=null:
    on-crash_ = on-crash
    on-error_ = on-error

  /**
  Builds the flags that are passed to the compiler.
  */
  build-run-flags --project-uri/string? -> List:
    project-path-compiler := translator.to-path project-uri --to-compiler
    args := [
      "--lsp",
      "--project-root", project-path-compiler,
    ]
    verbose: "run-flags: $args"
    return args

  /**
  Starts the compiler and calls the given [write_callback]/[read_callback] with the opened pipes.

  Returns whether the call was successful.
  If there was a crash, invokes the stored `on_crash` handler, and returns false.
  */
  run --project-uri/string? --ignore-crashes/bool=false --compiler-input/string [read-callback] -> bool:
    flags := build-run-flags --project-uri=project-uri

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

    timeout-task := null
    if timeout-ms_ > 0:
      timeout-task = task:: catch --trace:
        try:
          sleep --ms=timeout-ms_
          if not has-terminated:
            SIGKILL ::= 9
            pipe.kill_ cpp-pid SIGKILL
            was-killed-because-of-timeout = true
        finally:
          timeout-task = null

    did-crash := false
    try:
      writer := io.Writer.adapt cpp-to
      writer.write "$file-server-line\n"
      writer.write compiler-input

      reader := io.Reader.adapt to-parser
      read-callback.call reader
    finally:
      if timeout-task: timeout-task.cancel
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

  analyze --project-uri/string? uris/List -> AnalysisResult?:
    // Work around small stack size.
    // TODO(1268): remove work-around
    latch := monitor.Latch
    task:: catch --trace:
      paths := uris.map: | uri |
        path := translator.to-path uri --to-compiler
        // There are multiple ways to encode URIs. Check that the uri is already
        // canonicalized.
        assert: uri == (translator.to-uri path --from-compiler)
        path
      result := null

      verbose: "Calling compiler analysis with $paths"
      compiler-input := "ANALYZE\n$(paths.size)\n$(paths.join "\n")\n"
      completed-successfully := run --project-uri=project-uri --compiler-input=compiler-input:
        |reader /io.Reader|

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
              error-uri = translator.to-uri error-path --from-compiler
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

  /**
  Gets all the completion from the compiler and calls the given $block
    with a prefix, a prefix-range and a list of completions.
  If not completions are found, the block is called with the empty string and
    and empty list.
  */
  complete -> none
      --project-uri/string?
      uri/string
      line-number/int
      column-number/int
      [block]:
    path := translator.to-path uri --to-compiler
    // We don't care if the compiler crashed.
    // Just send whatever completions we get.
    run --project-uri=project-uri
        --compiler-input="COMPLETE\n$path\n$line-number\n$column-number\n":
      |reader /io.Reader|
      prefix := reader.read-line
      if not prefix:
        block.call "" null []
        return
      edit-range := read-range reader

      suggestions := []
      while true:
        line := reader.read-line
        if line == null: break
        kind := int.parse reader.read-line
        suggestions.add (CompletionItem --label=line --kind=kind)

      block.call prefix edit-range suggestions
      return
    unreachable

  goto-definition --project-uri/string? uri/string line-number/int column-number/int -> List/*<Location>*/:
    path := translator.to-path uri --to-compiler
    // We don't care if the compiler crashed.
    // Just send the definitions we got.
    run --project-uri=project-uri
        --compiler-input="GOTO DEFINITION\n$path\n$line-number\n$column-number\n":
      |reader /io.Reader|
      definitions := []

      while true:
        line := reader.read-line
        if line == null: break
        location := Location
          --uri= translator.to-uri line --from-compiler
          --range= read-range reader
        definitions.add location

      return definitions
    unreachable

  parse --project-uri/string? --paths/List/*<string>*/ -> bool:
    // Parse all files and fill the fileserver.
    return run
        --project-uri=project-uri
        --compiler-input="PARSE\n$paths.size\n$(paths.join "\n")\n":
      |reader /io.Reader|
      while true:
        // Just drain the reader.
        data := reader.read
        if not data: break

  snapshot-bundle --project-uri/string? uri/string -> ByteArray?:
    path := translator.to-path uri --to-compiler
    run --project-uri=project-uri
        --compiler-input="SNAPSHOT BUNDLE\n$path\n":
      |reader /io.Reader|
      status := reader.read-line
      if status != "OK": return null
      bundle-size := int.parse reader.read-line
      buffer := io.Buffer
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

  semantic-tokens --project-uri/string? uri/string -> List:
    path := translator.to-path uri --to-compiler
    run --project-uri=project-uri
        --compiler-input="SEMANTIC TOKENS\n$path\n":
      |reader /io.Reader|
      element-count := int.parse reader.read-line
      result := List element-count: int.parse reader.read-line
      return result
    unreachable

  static read-range reader/io.Reader -> Range:
    from-line-number := int.parse reader.read-line
    from-column-number := int.parse reader.read-line
    to-line-number := int.parse reader.read-line
    to-column-number := int.parse reader.read-line
    return Range
        Position from-line-number from-column-number
        Position to-line-number   to-column-number

  read-dependencies reader/io.Reader -> Map/*<string, Set<string>>*/:
    entry-count := int.parse reader.read-line
    result := {:}
    entry-count.repeat:
      source-uri := translator.to-uri reader.read-line --from-compiler
      direct-deps-count := int.parse reader.read-line
      direct-deps := {}
      direct-deps-count.repeat:
        direct-deps.add (translator.to-uri reader.read-line --from-compiler)
      result[source-uri] = direct-deps

    return result

  read-summary reader/io.Reader -> Map/*<path, Module>*/:
    return (SummaryReader reader).read-summary
