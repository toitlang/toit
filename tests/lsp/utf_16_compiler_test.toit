// Copyright (C) 2019 Toitware ApS. All rights reserved.

import .lsp_client show LspClient run_client_test
import expect show *

main args:
  run_client_test args: test it
  run_client_test --use_toitlsp args: test it

test client/LspClient:
  // Test that locations are correctly transformed to UTF-16 offsets.
  print "Checking UTF-16 location offsets."
  untitled_uri := "untitled:Untitled-4"
  client.send_did_open --uri=untitled_uri --text="""
    foo x y:
    main:
      foo "𝄞𝄞𝄞𝄞" (5 3)
      """
  diagnostics := client.diagnostics_for --uri=untitled_uri
  expect_equals 1 diagnostics.size
  diagnostic := diagnostics[0]
  expect_equals 2 diagnostic["range"]["start"]["line"]
  expect_equals 18 diagnostic["range"]["start"]["character"]

  // Test that completion works with UTF-16 characters.
  print "Checking completion and goto-definition in UTF-16 files."
  untitled_uri2 := "untitled:Untitled-5"
  client.send_did_open --uri=untitled_uri2 --text="""
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
  diagnostics = client.diagnostics_for --uri=untitled_uri2
  expect_equals 0 diagnostics.size

  print "Completion"
  for i := 18; i <= 21; i++:
    response := client.send_completion_request --uri=untitled_uri2 5 i
    found_foo := false
    response.do:
      if it["label"] == "foo": found_foo = true
    expect found_foo

  for i := 36; i <= 39; i++:
    response := client.send_completion_request --uri=untitled_uri2 5 i
    found_bar := false
    response.do:
      if it["label"] == "bar": found_bar = true
    expect found_bar

  // Test that definition works with UTF-16 characters.
  print "Definition"
  for i := 18; i <= 21; i++:
    response := client.send_goto_definition_request --uri=untitled_uri2 5 i
    expect_equals 1 response.size
    definition := response.first
    expect_equals untitled_uri2 definition["uri"]
    range := definition["range"]
    expect_equals 3 range["start"]["line"]
    expect_equals 0 range["start"]["character"]
    expect_equals 3 range["end"]["line"]
    expect_equals 3 range["end"]["character"]

  for i := 36; i <= 39; i++:
    response := client.send_goto_definition_request --uri=untitled_uri2 5 i
    expect_equals 1 response.size
    definition := response.first
    expect_equals untitled_uri2 definition["uri"]
    range := definition["range"]
    expect_equals 1 range["start"]["line"]
    expect_equals 2 range["start"]["character"]
    expect_equals 1 range["end"]["line"]
    expect_equals 5 range["end"]["character"]
