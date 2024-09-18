// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .lsp-client

class MockDiagnostic:
  path / string ::= ?
  message / string ::= ?
  start-line / int ::= ?
  start-column / int ::= ?
  end-line / int ::= ?
  end-column / int ::= ?

  constructor --.path .message .start-line .start-column .end-line=start-line .end-column=start-column:

  is-same-as-json json/Map -> bool:
    return json["message"] == message and
        json["range"]["start"]["line"] == start-line and
        json["range"]["start"]["character"] == start-column and
        json["range"]["end"]["line"] == end-line and
        json["range"]["end"]["character"] == end-column

  to-compiler-format -> string:
    return """
      WITH POSITION
      error
      $path
      $start-line
      $start-column
      $end-line
      $end-column
      $message
      *******************
      """

class MockData:
  diagnostics / List := ?
  deps / List := ?

  constructor .diagnostics .deps:

class MockCompiler:
  static MOCK-PREFIX ::= "mock:"
  static ANALYZE-MOCK-FILE ::= MOCK-PREFIX + "ANALYZE"
  static DUMP-FILE-NAMES-MOCK-FILE ::= MOCK-PREFIX + "DUMP_FILE_NAMES"
  static COMPLETE-FILE ::= MOCK-PREFIX + "COMPLETE"

  mock-information_ / Map/*<path/string, MockData>*/ ::= {:}

  lsp-client_ / LspClient ::= ?
  opened-mock-files_ / Set ::= {}

  constructor .lsp-client_:

  set-mock-data --path/string data/MockData:
    mock-information_[path] = data

  set-analysis-result answer/string -> none:
    set-mock-file-content ANALYZE-MOCK-FILE answer

  set-dump-file-names-result answer/string -> none:
    set-mock-file-content DUMP-FILE-NAMES-MOCK-FILE answer

  set-completion-result answer/string -> none:
    set-mock-file-content COMPLETE-FILE answer

  set-mock-file-content uri text:
    if opened-mock-files_.contains uri:
      lsp-client_.send-did-change --uri=uri text
    else:
      opened-mock-files_.add uri
      lsp-client_.send-did-open --uri=uri --text=text

  build-analysis-answer --should-crash=false --delay-us=null --path/string -> string:
    summary-string := build-summary_ path
    diagnostics-string := build-diagnostics_ path
    analysis-answer := summary-string + "\n" + diagnostics-string
    if delay-us: analysis-answer = "SLOW\n$delay-us\n" + analysis-answer
    if should-crash: analysis-answer = "CRASH\n" + analysis-answer
    return analysis-answer

  build-deps_ data --chunks/List:
    if not data:
      chunks.add "1"
      chunks.add "/CORE"
    else:
      chunks.add data.deps.size + 1
      chunks.add "/CORE"
      chunks.add-all data.deps

  build-summary_ entry-path -> string:
    chunks := []
    build-summary_ entry-path --chunks=chunks
    return "SUMMARY\n" + (chunks.join "\n") + "\n"

  build-summary_ path --chunks/List -> none:
    all-uris := {}
    mock-information_.do: |uri data|
      all-uris.add uri
      all-uris.add-all data.deps

    chunks.add all-uris.size
    all-uris.do:
      chunks.add it
      chunks.add 0  // Currently there are no toplevel elements in the modules.
    all-uris.do:
      data := mock-information_.get it
      chunks.add it
      build-deps_ data --chunks=chunks
      // The external hash is 20 bytes, but we join all chunks with a "\n" above.
      // As such we only add 19 bytes here and let the 20th byte be a '\n'.
      chunks.add ("a" * 19)
      // For now, just provide empty summaries.
      chunks.add 7 * 2  // The following 6 entries take one byte for the number/'-' and one for the '\n'.
      chunks.add "-"
      chunks.add 0 // No transitive exports.
      chunks.add 0 // Exported identifiers.
      chunks.add 0 // Classes
      chunks.add 0 // Methods
      chunks.add 0 // Globals
      chunks.add 0 // Toitdoc

  build-diagnostics_ entry-path/string -> string:
    chunks := []
    build-diagnostics_ entry-path --seen={} --chunks=chunks
    return chunks.join "\n" + "\n"

  build-diagnostics_ path/string --seen/Set --chunks/List -> none:
    if seen.contains path: return
    seen.add path
    data := mock-information_.get path
    if not data: return
    chunks.add-all
        data.diagnostics.map: it.to-compiler-format
    data.deps.do: build-diagnostics_ it --seen=seen --chunks=chunks
