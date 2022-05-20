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
import .file_server
import .summary show SummaryReader
import .uri_path_translator
import .utils
import .verbose
import .multiplex

class AnalysisResult:
  diagnostics / Map/*<uri/string, Diagnostics>*/ ::= ?
  diagnostics_without_position / List/*<string>*/ ::= ?
  summaries / Map?/*<uri/string, Module>*/ ::= ?

  constructor .diagnostics .diagnostics_without_position .summaries:

class Compiler:
  compiler_path_       /string             ::= ?
  uri_path_translator_ /UriPathTranslator  ::= ?
  on_crash_            /Lambda?     ::= ?
  on_error_            /Lambda?     ::= ?
  timeout_ms_          /int         ::= ?
  protocol             /FileServerProtocol ::= ?
  project_path_        /string?     ::= ?

  constructor
      .compiler_path_
      .uri_path_translator_
      .timeout_ms_
      --.protocol
      --project_path/string?
      --on_error/Lambda?=null
      --on_crash/Lambda?=null:
    on_crash_ = on_crash
    on_error_ = on_error
    project_path_ = project_path

  /**
  Builds the flags that are passed to the compiler.
  */
  build_run_flags -> List:
    args := [
      "--lsp",
    ]
    if project_path_:
      package_lock := "$project_path_/package.lock"
      if file.is_file package_lock:
        args += ["--project-root", project_path_]
    return args

  /**
  Starts the compiler and calls the given [write_callback]/[read_callback] with the opened pipes.

  Returns whether the call was successful.
  If there was a crash, invokes the stored `on_crash` handler, and returns false.
  */
  run --ignore_crashes/bool=false --compiler_input/string [read_callback] -> bool:
    flags := build_run_flags

    cpp_pipes := pipe.fork
        true                // use_path
        pipe.PIPE_CREATED   // stdin
        pipe.PIPE_CREATED   // stdout
        pipe.PIPE_INHERITED // stderr
        compiler_path_
        [compiler_path_] + flags
    cpp_to   := cpp_pipes[0]
    cpp_from := cpp_pipes[1]
    cpp_pid  := cpp_pipes[3]


    has_terminated := false
    was_killed_because_of_timeout := false

    multiplex := MultiplexConnection cpp_from
    multiplex.start_dispatch
    to_parser := multiplex.compiler_to_parser
    file_server := PipeFileServer protocol cpp_to multiplex.compiler_to_fs
    file_server_line := file_server.run

    if timeout_ms_ > 0:
      task:: catch --trace:
        sleep --ms=timeout_ms_
        if not has_terminated:
          SIGKILL ::= 9
          pipe.kill_ cpp_pid SIGKILL
          was_killed_because_of_timeout = true

    did_crash := false
    try:
      writer := Writer cpp_to
      writer.write "$file_server_line\n"
      writer.write compiler_input

      reader := BufferedReader to_parser
      read_callback.call reader
    finally:
      file_server.close
      to_parser.close
      multiplex.close

      exit_value := pipe.wait_for cpp_pid
      verbose: "Compiler terminated with exit_signal: $(pipe.exit_signal exit_value)"
      has_terminated = true
      if not ignore_crashes:
        exit_signal := pipe.exit_signal exit_value
        if exit_signal:
          // Assume that any exit-signal was because of a crash of the compiler.
          if on_crash_:
            reason := (pipe.signal_to_string exit_signal)
            if was_killed_because_of_timeout: reason += "\nKilled after timeout"
            on_crash_.call flags compiler_input reason file_server.protocol
          did_crash = true
    return not did_crash

  analyze uris/List -> AnalysisResult?:
    // Work around small stack size.
    // TODO(1268): remove work-around
    latch := monitor.Latch
    task:: catch --trace:
      paths := uris.map: | uri |
        path := uri_path_translator_.to_path uri
        // There are multiple ways to encode URIs. Check that the uri is already
        // canonicalized.
        assert: uri == (uri_path_translator_.to_uri path)
        path
      result := null

      verbose: "Calling compiler analysis with $paths"
      compiler_input := "ANALYZE\n$(paths.size)\n$(paths.join "\n")\n"
      completed_successfully := run --compiler_input=compiler_input:
        |reader /BufferedReader|

        summary := null

        diagnostics_per_uri := Map
        diagnostics_without_position := []

        in_group := false
        group_uri := null
        group_diagnostic := null
        related_information := null
        while true:
          line := reader.read_line
          if line == null: break
          if line == "": continue  // Empty lines are allowed.
          if line == "SUMMARY":
            assert: summary == null
            summary = read_summary reader
          else if line == "START GROUP":
            assert: not in_group
            assert: group_diagnostic == null
            assert: related_information == null
            in_group = true
          else if line == "END GROUP":
            group_diagnostic.related_information = related_information
            (diagnostics_per_uri.get group_uri --init=(: [])).add group_diagnostic
            in_group = false
            group_uri = null
            group_diagnostic = null
            related_information = null
          else if line == "WITH POSITION" or line == "NO POSITION":
            with_position := line == "WITH POSITION"
            severity := reader.read_line
            error_path := null
            error_uri := null
            range := null
            if with_position:
              error_path = reader.read_line
              error_uri = uri_path_translator_.to_uri error_path
              range = read_range reader
            msg := ""
            while true:
              line = reader.read_line
              if line == "*******************": break
              msg += line

            diagnostic_severity := ?
            if severity == "error":
              diagnostic_severity = DiagnosticSeverity.error
            else if severity == "warning":
              diagnostic_severity = DiagnosticSeverity.warning
            else:
              assert: severity == "information"
              diagnostic_severity = DiagnosticSeverity.information
            if not with_position:
              verbose: "Diagnostic without position: $msg"
              diagnostics_without_position.add msg
            else if not in_group:
              verbose: "Diagnostic for $error_uri: $msg"
              (diagnostics_per_uri.get error_uri --init=(: [])).add
                  Diagnostic
                    --range=    range
                    --message=  msg
                    --severity= diagnostic_severity
            else:
              if group_uri == null:
                verbose: "Starting group diagnostic for $error_uri: $msg"
                group_uri = error_uri
                group_diagnostic = Diagnostic
                    --range=    range
                    --message=  msg
                    --severity= diagnostic_severity
                related_information = []
              else:
                related_information.add
                    DiagnosticRelatedInformation
                        --location= Location
                            --uri=   error_uri
                            --range= range
                        --message=msg
          else:
            // Just ignore the message for now.
            if on_error_: on_error_.call "LSP Server: unexpected line from compiler: $line"
          result = AnalysisResult diagnostics_per_uri diagnostics_without_position summary
      latch.set (completed_successfully ? result : null)
    return latch.get

  complete uri/string line_number/int column_number/int -> List/*<string>*/:
    path := uri_path_translator_.to_path uri
    // We don't care if the compiler crashed.
    // Just send whatever completions we get.
    run --compiler_input="COMPLETE\n$path\n$line_number\n$column_number\n":
      |reader /BufferedReader|
      suggestions := []

      while true:
        line := reader.read_line
        if line == null: break
        kind := int.parse reader.read_line
        suggestions.add (CompletionItem --label=line --kind=kind)
      return suggestions
    unreachable

  goto_definition uri/string line_number/int column_number/int -> List/*<Location>*/:
    path := uri_path_translator_.to_path uri
    // We don't care if the compiler crashed.
    // Just send the definitions we got.
    run --compiler_input="GOTO DEFINITION\n$path\n$line_number\n$column_number\n":
      |reader /BufferedReader|
      definitions := []

      while true:
        line := reader.read_line
        if line == null: break
        location := Location
          --uri= uri_path_translator_.to_uri line
          --range= read_range reader
        definitions.add location

      return definitions
    unreachable

  parse --paths/List/*<string>*/ -> bool:
    // Parse all files and fill the fileserver.
    return run --compiler_input="PARSE\n$paths.size\n$(paths.join "\n")\n":
      |reader /BufferedReader|
      while true:
        // Just drain the reader.
        data := reader.read
        if not data: break

  snapshot_bundle uri/string -> ByteArray?:
    path := uri_path_translator_.to_path uri
    run --compiler_input="SNAPSHOT BUNDLE\n$path\n":
      |reader /BufferedReader|
      status := reader.read_line
      if status != "OK": return null
      bundle_size := int.parse reader.read_line
      buffer := bytes.Buffer
      buffer.reserve bundle_size
      while data := reader.read:
        buffer.write data
      if buffer.size != bundle_size: return null
      return buffer.bytes
    unreachable

  static SEMANTIC_TOKEN_TYPES ::= [
    "namespace",
    "class",
    "interface",
    "parameter",
    "variable",
  ]
  static SEMANTIC_TOKEN_MODIFIERS ::= [
    "definition",
    "readonly",
    "static",
    "abstract",
    "defaultLibrary",
  ]

  semantic_tokens uri/string -> List:
    path := uri_path_translator_.to_path uri
    run --compiler_input="SEMANTIC TOKENS\n$path\n":
      |reader /BufferedReader|
      element_count := int.parse reader.read_line
      result := List element_count: int.parse reader.read_line
      return result
    unreachable

  static read_range reader/BufferedReader -> Range:
    from_line_number := int.parse reader.read_line
    from_column_number := int.parse reader.read_line
    to_line_number := int.parse reader.read_line
    to_column_number := int.parse reader.read_line
    return Range
        Position from_line_number from_column_number
        Position to_line_number   to_column_number

  read_dependencies reader/BufferedReader -> Map/*<string, Set<string>>*/:
    entry_count := int.parse reader.read_line
    result := {:}
    entry_count.repeat:
      source_uri := uri_path_translator_.to_uri reader.read_line
      direct_deps_count := int.parse reader.read_line
      direct_deps := {}
      direct_deps_count.repeat: direct_deps.add (uri_path_translator_.to_uri reader.read_line)
      result[source_uri] = direct_deps

    return result

  read_summary reader/BufferedReader -> Map/*<path, Module>*/:
    return (SummaryReader reader uri_path_translator_).read_summary
