// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .lsp_client show LspClient run_client_test
import host.directory
import expect show *

main args:
  run_client_test args: test it
  run_client_test --use_toitlsp args: test it

test client/LspClient:
  protocol1 := "$(directory.cwd)/protocol1.toit"
  protocol2 := "$(directory.cwd)/protocol2.toit"
  protocol3 := "$(directory.cwd)/protocol3.toit"
  // Canonicalize paths to avoid problems with Windows paths.
  protocol1 = client.to_path (client.to_uri protocol1)
  protocol2 = client.to_path (client.to_uri protocol2)
  protocol3 = client.to_path (client.to_uri protocol3)

  files_to_open := [
    [protocol1, 0],
    [protocol2, 1],
    [protocol3, 0],
  ]

  files_to_open.do: | test |
    print "Running test $test"
    path := test[0]
    expected_diagnostics := test[1]
    client.send_did_open --path=path
    diagnostics := client.diagnostics_for --path=path
    expect_equals expected_diagnostics diagnostics.size

  print "Changing protocol1"
  client.send_did_change --path=protocol1 """
    foo x:
    main:
      print 1 2
      print 2 3
    """
  diagnostics := client.diagnostics_for --path=protocol1
  expect_equals 2 diagnostics.size

  // The protocol3 test imports protocol1, but should still be ok.
  // In theory it could contain the errors of protocol1, but we filter them out right now.
  print "Checking that protocol3 still doesn't have errors"
  client.send_did_close --path=protocol3

  client.send_did_open --path=protocol3
  diagnostics = client.diagnostics_for --path=protocol3
  expect_equals 0 diagnostics.size

  // Close protocol3.
  // This is mainly to make the test less brittle.
  // The server reasonably could send diagnostics for all files that are
  // open, instead of waiting for new changes to the file.
  print "Closing protocol3 before breaking change"
  client.send_did_close --path=protocol3

  print "Changing protocol1 again (breaking protocol3)"
  client.send_did_change --path=protocol1 """
    foo x y:
    main:
      print 1
    """
  diagnostics = client.diagnostics_for --path=protocol1
  expect_equals 0 diagnostics.size

  print "Checking that protocol3 now has errors"
  client.send_did_open --path=protocol3
  diagnostics = client.diagnostics_for --path=protocol3
  expect_equals 1 diagnostics.size

  print "Closing protocol3 before save"
  client.send_did_close --path=protocol3

  // We don't expect any diagnostics here, as editors (at least VSCode)
  // send a change-notification before saving.
  // The server therefore doesn't need to run another validation at that point.
  print "(fake) saving protocol1"
  client.send_did_save --path=protocol1

  // The unsaved-file cache in the server must be cleared now (for protocol1).
  print "Checking that protocol3 is now free of errors again"

  client.send_did_open --path=protocol3
  diagnostics = client.diagnostics_for --path=protocol3
  expect_equals 0 diagnostics.size

  // Test non-existing files.
  print "Checking that non-existing files work"
  untitled_uri := "untitled:Untitled-1"
  client.send_did_open --uri=untitled_uri
        --text="""
    main: print 1 2
    """
  diagnostics = client.diagnostics_for --uri=untitled_uri
  expect_equals 1 diagnostics.size

  client.send_did_change --uri=untitled_uri """
    main: print 1
    """
  diagnostics = client.diagnostics_for --uri=untitled_uri
  expect_equals 0 diagnostics.size

  client.send_did_change --uri=untitled_uri """
    import .foo  // Relative imports are not allowed.
    main: print 1
    """
  diagnostics = client.diagnostics_for --uri=untitled_uri
  expect_equals 1 diagnostics.size

  // Check completion
  print "Checking completion in (changed) protocol2"
  client.send_did_change --path=protocol2 """
    foo x:
    main: f 5
    """
  diagnostics = client.diagnostics_for --path=protocol2
  expect_equals 1 diagnostics.size
  response := client.send_completion_request --path=protocol2 1 7
  found_foo := false
  response.do:
    if it["label"] == "foo": found_foo = true
  expect found_foo

  client.send_did_change --path=protocol2 """
    import .protocol1
    main: f 5
    """
  diagnostics = client.diagnostics_for --path=protocol2
  expect_equals 1 diagnostics.size
  response = client.send_completion_request --path=protocol2 1 7
  found_foo = false
  response.do:
    if it["label"] == "foo": found_foo = true
  expect found_foo

  // Check goto-definition
  print "Checking goto-definition in (changed) protocol2"
  client.send_did_change --path=protocol2 """
    foo x:
    main: foo 5
    """
  diagnostics = client.diagnostics_for --path=protocol2
  expect_equals 0 diagnostics.size
  response = client.send_goto_definition_request --path=protocol2 1 7
  expect_equals 1 response.size
  definition := response.first
  expect_equals protocol2 (client.to_path definition["uri"])
  range := definition["range"]
  expect_equals 0 range["start"]["line"]
  expect_equals 0 range["start"]["character"]
  expect_equals 0 range["end"]["line"]
  expect_equals 3 range["end"]["character"]

  client.send_did_change --path=protocol1 """
    // Commented first line.
    foo x:
    """
  diagnostics = client.diagnostics_for --path=protocol1
  expect_equals 0 diagnostics.size

  client.send_did_change --path=protocol2 """
    import .protocol1
    main: foo 5
    """
  diagnostics = client.diagnostics_for --path=protocol2
  expect_equals 0 diagnostics.size
  response = client.send_goto_definition_request --path=protocol2 1 7
  expect_equals 1 response.size
  definition = response.first
  expect_equals protocol1 (client.to_path definition["uri"])
  range = definition["range"]
  expect_equals 1 range["start"]["line"]
  expect_equals 0 range["start"]["character"]
  expect_equals 1 range["end"]["line"]
  expect_equals 3 range["end"]["character"]

  // Test that goto-definition works in unsaved files.
  print "Checking goto-definition in unsaved files"
  untitled_uri2 := "untitled:Untitled-2"
  client.send_did_open --uri=untitled_uri2 --text="""
    foo x:
    main: foo 5"""
  diagnostics = client.diagnostics_for --uri=untitled_uri2
  expect_equals 0 diagnostics.size
  response = client.send_goto_definition_request --uri=untitled_uri2 1 7
  expect_equals 1 response.size
  definition = response.first
  expect_equals untitled_uri2 definition["uri"]
  range = definition["range"]
  expect_equals 0 range["start"]["line"]
  expect_equals 0 range["start"]["character"]
  expect_equals 0 range["end"]["line"]
  expect_equals 3 range["end"]["character"]

  // Test that completion works at the end of file when there isn't a new-line.
  print "Checking completion in file without trailing newline"
  untitled_uri3 := "untitled:Untitled-3"
  client.send_did_open --uri=untitled_uri3 --text="""
    foo x:
    main: """
  diagnostics = client.diagnostics_for --uri=untitled_uri3
  expect_equals 0 diagnostics.size
  response = client.send_completion_request --uri=untitled_uri3 1 6
  found_foo = false
  response.do:
    if it["label"] == "foo": found_foo = true
  expect found_foo

  // Check that group errors work.
  print "Checking group errors"
  ERROR ::= 1
  WARNING ::= 2
  group_test_path := "$(directory.cwd)/group_test.toit"

  client.send_did_open --path=group_test_path --text="""
    import .ambiguous_a
    import .ambiguous_b
    main:
      foo
    """
  diagnostics = client.diagnostics_for --path=group_test_path
  expect_equals 1 diagnostics.size
  diagnostic := diagnostics.first
  expect_equals ERROR diagnostic["severity"]
  expect_equals 2 diagnostic["relatedInformation"].size

  client.send_did_open --path=group_test_path --text="""
    import .ambiguous_a
    import .ambiguous_b
    /** \$foo */
    main:
    """
  diagnostics = client.diagnostics_for --path=group_test_path
  expect_equals 1 diagnostics.size
  diagnostic = diagnostics.first
  expect_equals WARNING diagnostic["severity"]
  expect_equals 2 diagnostic["relatedInformation"].size

  response = client.send_request "toit/non_existing"  {:}
  expect (response.contains "code")
  UNKNOWN_ERROR_CODE ::= -32601
  expect_equals UNKNOWN_ERROR_CODE response["code"]
