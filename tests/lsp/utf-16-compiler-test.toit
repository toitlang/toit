// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .lsp-client show LspClient run-client-test
import expect show *

main args:
  run-client-test args: test it

test client/LspClient:
  // Test that locations are correctly transformed to UTF-16 offsets.
  print "Checking UTF-16 location offsets."
  untitled-uri := "untitled:Untitled-4"
  client.send-did-open --uri=untitled-uri --text="""
    foo x y:
    main:
      foo "𝄞𝄞𝄞𝄞" (5 3)
      """
  diagnostics := client.diagnostics-for --uri=untitled-uri
  expect-equals 1 diagnostics.size
  diagnostic := diagnostics[0]
  expect-equals 2 diagnostic["range"]["start"]["line"]
  expect-equals 18 diagnostic["range"]["start"]["character"]

  // Test that completion works with UTF-16 characters.
  print "Checking completion and goto-definition in UTF-16 files."
  untitled-uri2 := "untitled:Untitled-5"
  client.send-did-open --uri=untitled-uri2 --text="""
    class A:
      bar:

    foo x y -> A: unreachable
    main:
      foo "𝄞𝄞𝄞𝄞" (foo "𝄞𝄞𝄞𝄞" 5).bar
    //            foo          .bar   (duplicated here, because some editors don't show the 𝄞 as fixed width.)
    //            ^18           ^36
    // 7 characters before the first 𝄞.
    // 8 characters because of the 4 𝄞, each taking 2 UTF-16 chars.
    // 3 characters after the last 𝄞.
    """
  diagnostics = client.diagnostics-for --uri=untitled-uri2
  expect-equals 0 diagnostics.size

  print "Completion"
  for i := 18; i <= 21; i++:
    response := client.send-completion-request --uri=untitled-uri2 5 i
    found-foo := false
    response.do:
      if it["label"] == "foo": found-foo = true
    expect found-foo

  for i := 36; i <= 39; i++:
    response := client.send-completion-request --uri=untitled-uri2 5 i
    found-bar := false
    response.do:
      if it["label"] == "bar": found-bar = true
    expect found-bar

  // Test that definition works with UTF-16 characters.
  print "Definition"
  for i := 18; i <= 21; i++:
    response := client.send-goto-definition-request --uri=untitled-uri2 5 i
    expect-equals 1 response.size
    definition := response.first
    expect-equals untitled-uri2 definition["uri"]
    range := definition["range"]
    expect-equals 3 range["start"]["line"]
    expect-equals 0 range["start"]["character"]
    expect-equals 3 range["end"]["line"]
    expect-equals 3 range["end"]["character"]

  for i := 36; i <= 39; i++:
    response := client.send-goto-definition-request --uri=untitled-uri2 5 i
    expect-equals 1 response.size
    definition := response.first
    expect-equals untitled-uri2 definition["uri"]
    range := definition["range"]
    expect-equals 1 range["start"]["line"]
    expect-equals 2 range["start"]["character"]
    expect-equals 1 range["end"]["line"]
    expect-equals 5 range["end"]["character"]
