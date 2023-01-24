// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .lsp_client

class MockDiagnostic:
  path / string ::= ?
  message / string ::= ?
  start_line / int ::= ?
  start_column / int ::= ?
  end_line / int ::= ?
  end_column / int ::= ?

  constructor --.path .message .start_line .start_column .end_line=start_line .end_column=start_column:

  is_same_as_json json/Map -> bool:
    return json["message"] == message and
        json["range"]["start"]["line"] == start_line and
        json["range"]["start"]["character"] == start_column and
        json["range"]["end"]["line"] == end_line and
        json["range"]["end"]["character"] == end_column

  to_compiler_format -> string:
    return """
      WITH POSITION
      error
      $path
      $start_line
      $start_column
      $end_line
      $end_column
      $message
      *******************
      """

class MockData:
  diagnostics / List := ?
  deps / List := ?

  constructor .diagnostics .deps:

class MockCompiler:
  static MOCK_PREFIX ::= "mock:"
  static ANALYZE_MOCK_FILE ::= MOCK_PREFIX + "ANALYZE"
  static DUMP_FILE_NAMES_MOCK_FILE ::= MOCK_PREFIX + "DUMP_FILE_NAMES"
  static COMPLETE_FILE ::= MOCK_PREFIX + "COMPLETE"

  mock_information_ / Map/*<path/string, MockData>*/ ::= {:}

  lsp_client_ / LspClient ::= ?
  opened_mock_files_ / Set ::= {}

  constructor .lsp_client_:

  set_mock_data --path/string data/MockData:
    mock_information_[path] = data

  set_analysis_result answer/string -> none:
    set_mock_file_content ANALYZE_MOCK_FILE answer

  set_dump_file_names_result answer/string -> none:
    set_mock_file_content DUMP_FILE_NAMES_MOCK_FILE answer

  set_completion_result answer/string -> none:
    set_mock_file_content COMPLETE_FILE answer

  set_mock_file_content uri text:
    if opened_mock_files_.contains uri:
      lsp_client_.send_did_change --uri=uri text
    else:
      opened_mock_files_.add uri
      lsp_client_.send_did_open --uri=uri --text=text

  build_analysis_answer --should_crash=false --delay_us=null --path/string -> string:
    summary_string := build_summary_ path
    diagnostics_string := build_diagnostics_ path
    analysis_answer := summary_string + "\n" + diagnostics_string
    if delay_us: analysis_answer = "SLOW\n$delay_us\n" + analysis_answer
    if should_crash: analysis_answer = "CRASH\n" + analysis_answer
    return analysis_answer

  build_deps_ data --chunks/List:
    if not data:
      chunks.add "1"
      chunks.add "/CORE"
    else:
      chunks.add data.deps.size + 1
      chunks.add "/CORE"
      chunks.add_all data.deps

  build_summary_ entry_path -> string:
    chunks := []
    build_summary_ entry_path --chunks=chunks
    return "SUMMARY\n" + (chunks.join "\n") + "\n"

  build_summary_ path --chunks/List --class_count_only=false -> none:
    all_uris := {}
    mock_information_.do: |uri data|
      all_uris.add uri
      all_uris.add_all data.deps

    chunks.add all_uris.size
    all_uris.do:
      chunks.add it
      chunks.add 0  // Currently there are no toplevel elements in the modules.
    all_uris.do:
      data := mock_information_.get it
      chunks.add it
      build_deps_ data --chunks=chunks
      // For now, just provide empty summaries.
      if class_count_only:
        chunks.add 0 // Classes
      else:
        chunks.add 0 // No transitive exports.
        chunks.add 0 // Exported identifiers.
        chunks.add 0 // Classes
        chunks.add 0 // Methods
        chunks.add 0 // Globals
        chunks.add 0 // Toitdoc

  build_diagnostics_ entry_path/string -> string:
    chunks := []
    build_diagnostics_ entry_path --seen={} --chunks=chunks
    return chunks.join "\n" + "\n"

  build_diagnostics_ path/string --seen/Set --chunks/List -> none:
    if seen.contains path: return
    seen.add path
    data := mock_information_.get path
    if not data: return
    chunks.add_all
        data.diagnostics.map: it.to_compiler_format
    data.deps.do: build_diagnostics_ it --seen=seen --chunks=chunks
