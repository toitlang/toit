// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .lsp-client show LspClient run-client-test
import expect show *

// Regression test for https://github.com/toitlang/toit/issues/2950.
//
// The LSP server is asynchronous: a `did-change` that arrives between when
// a completion request is queued and when the forked compiler actually
// reads the buffer can leave the compiler with a (line, col) position that
// is past the end of the (now shorter) line. The compiler must clamp the
// position instead of aborting on `compute_source_offset`'s UNREACHABLE.
//
// We can't easily replay that exact race in a test, so we approximate it
// by asking for completion at LSP positions that are explicitly past the
// end of the line (and past the end of the file). Both used to crash;
// after the fix they must just return without aborting.

main args:
  run-client-test args: test it

test client/LspClient:
  // A small file whose last line has no trailing newline -- exactly the
  // shape the original repros had (line beyond EOF / col beyond EOL).
  untitled-uri := "untitled:Untitled-past-eol"
  client.send-did-open --uri=untitled-uri --text="""
      interface I_ implements:

      foo"""

  // Line 0 = "interface I_ implements:" (24 chars). Past-EOL column.
  client.send-completion-request --uri=untitled-uri 0 80

  // Line 2 = "foo" (3 chars, no trailing newline). Past-EOL column.
  client.send-completion-request --uri=untitled-uri 2 80

  // A line that does not exist at all (file only has 3 lines: 0..2).
  client.send-completion-request --uri=untitled-uri 99 0
  client.send-completion-request --uri=untitled-uri 99 80

  // Sanity check that the server is still alive and returning meaningful
  // completions for an in-bounds position.
  response := client.send-completion-request --uri=untitled-uri 2 3
  expect (response is List)
