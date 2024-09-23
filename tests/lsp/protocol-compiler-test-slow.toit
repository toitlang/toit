// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .lsp-client show LspClient run-client-test
import host.directory
import expect show *

main args:
  run-client-test args: test it

test client/LspClient:
  protocol1 := "$(directory.cwd)/protocol1.toit"
  protocol2 := "$(directory.cwd)/protocol2.toit"
  protocol3 := "$(directory.cwd)/protocol3.toit"
  // Canonicalize paths to avoid problems with Windows paths.
  protocol1 = client.to-path (client.to-uri protocol1)
  protocol2 = client.to-path (client.to-uri protocol2)
  protocol3 = client.to-path (client.to-uri protocol3)

  files-to-open := [
    [protocol1, 0],
    [protocol2, 1],
    [protocol3, 0],
  ]

  files-to-open.do: | test |
    print "Running test $test"
    path := test[0]
    expected-diagnostics := test[1]
    client.send-did-open --path=path
    diagnostics := client.diagnostics-for --path=path
    expect-equals expected-diagnostics diagnostics.size

  print "Changing protocol1"
  client.send-did-change --path=protocol1 """
    foo x:
    main:
      print 1 2
      print 2 3
    """
  diagnostics := client.diagnostics-for --path=protocol1
  expect-equals 2 diagnostics.size

  // The protocol3 test imports protocol1, but should still be ok.
  // In theory it could contain the errors of protocol1, but we filter them out right now.
  print "Checking that protocol3 still doesn't have errors"
  client.send-did-close --path=protocol3

  client.send-did-open --path=protocol3
  diagnostics = client.diagnostics-for --path=protocol3
  expect-equals 0 diagnostics.size

  // Close protocol3.
  // This is mainly to make the test less brittle.
  // The server reasonably could send diagnostics for all files that are
  // open, instead of waiting for new changes to the file.
  print "Closing protocol3 before breaking change"
  client.send-did-close --path=protocol3

  print "Changing protocol1 again (breaking protocol3)"
  client.send-did-change --path=protocol1 """
    foo x y:
    main:
      print 1
    """
  diagnostics = client.diagnostics-for --path=protocol1
  expect-equals 0 diagnostics.size

  print "Checking that protocol3 now has errors"
  client.send-did-open --path=protocol3
  diagnostics = client.diagnostics-for --path=protocol3
  expect-equals 1 diagnostics.size

  print "Closing protocol3 before save"
  client.send-did-close --path=protocol3

  // We don't expect any diagnostics here, as editors (at least VSCode)
  // send a change-notification before saving.
  // The server therefore doesn't need to run another validation at that point.
  print "(fake) saving protocol1"
  client.send-did-save --path=protocol1

  // The unsaved-file cache in the server must be cleared now (for protocol1).
  print "Checking that protocol3 is now free of errors again"

  client.send-did-open --path=protocol3
  diagnostics = client.diagnostics-for --path=protocol3
  expect-equals 0 diagnostics.size

  // Test non-existing files.
  print "Checking that non-existing files work"
  untitled-uri := "untitled:Untitled-1"
  client.send-did-open --uri=untitled-uri
        --text="""
    main: print 1 2
    """
  diagnostics = client.diagnostics-for --uri=untitled-uri
  expect-equals 1 diagnostics.size

  client.send-did-change --uri=untitled-uri """
    main: print 1
    """
  diagnostics = client.diagnostics-for --uri=untitled-uri
  expect-equals 0 diagnostics.size

  client.send-did-change --uri=untitled-uri """
    import .foo  // Relative imports are not allowed.
    main: print 1
    """
  diagnostics = client.diagnostics-for --uri=untitled-uri
  expect-equals 1 diagnostics.size

  // Check completion
  print "Checking completion in (changed) protocol2"
  client.send-did-change --path=protocol2 """
    foo x:
    main: f 5
    """
  diagnostics = client.diagnostics-for --path=protocol2
  expect-equals 1 diagnostics.size
  response := client.send-completion-request --path=protocol2 1 7
  found-foo := false
  response.do:
    if it["label"] == "foo": found-foo = true
  expect found-foo

  client.send-did-change --path=protocol2 """
    import .protocol1
    main: f 5
    """
  diagnostics = client.diagnostics-for --path=protocol2
  expect-equals 1 diagnostics.size
  response = client.send-completion-request --path=protocol2 1 7
  found-foo = false
  response.do:
    if it["label"] == "foo": found-foo = true
  expect found-foo

  // Check goto-definition
  print "Checking goto-definition in (changed) protocol2"
  client.send-did-change --path=protocol2 """
    foo x:
    main: foo 5
    """
  diagnostics = client.diagnostics-for --path=protocol2
  expect-equals 0 diagnostics.size
  response = client.send-goto-definition-request --path=protocol2 1 7
  expect-equals 1 response.size
  definition := response.first
  expect-equals protocol2 (client.to-path definition["uri"])
  range := definition["range"]
  expect-equals 0 range["start"]["line"]
  expect-equals 0 range["start"]["character"]
  expect-equals 0 range["end"]["line"]
  expect-equals 3 range["end"]["character"]

  client.send-did-change --path=protocol1 """
    // Commented first line.
    foo x:
    """
  diagnostics = client.diagnostics-for --path=protocol1
  expect-equals 0 diagnostics.size

  client.send-did-change --path=protocol2 """
    import .protocol1
    main: foo 5
    """
  diagnostics = client.diagnostics-for --path=protocol2
  expect-equals 0 diagnostics.size
  response = client.send-goto-definition-request --path=protocol2 1 7
  expect-equals 1 response.size
  definition = response.first
  expect-equals protocol1 (client.to-path definition["uri"])
  range = definition["range"]
  expect-equals 1 range["start"]["line"]
  expect-equals 0 range["start"]["character"]
  expect-equals 1 range["end"]["line"]
  expect-equals 3 range["end"]["character"]

  // Test that goto-definition works in unsaved files.
  print "Checking goto-definition in unsaved files"
  untitled-uri2 := "untitled:Untitled-2"
  client.send-did-open --uri=untitled-uri2 --text="""
    foo x:
    main: foo 5"""
  diagnostics = client.diagnostics-for --uri=untitled-uri2
  expect-equals 0 diagnostics.size
  response = client.send-goto-definition-request --uri=untitled-uri2 1 7
  expect-equals 1 response.size
  definition = response.first
  expect-equals untitled-uri2 definition["uri"]
  range = definition["range"]
  expect-equals 0 range["start"]["line"]
  expect-equals 0 range["start"]["character"]
  expect-equals 0 range["end"]["line"]
  expect-equals 3 range["end"]["character"]

  // Test that completion works at the end of file when there isn't a new-line.
  print "Checking completion in file without trailing newline"
  untitled-uri3 := "untitled:Untitled-3"
  client.send-did-open --uri=untitled-uri3 --text="""
    foo x:
    main: """
  diagnostics = client.diagnostics-for --uri=untitled-uri3
  expect-equals 0 diagnostics.size
  response = client.send-completion-request --uri=untitled-uri3 1 6
  found-foo = false
  response.do:
    if it["label"] == "foo": found-foo = true
  expect found-foo

  // Check that group errors work.
  print "Checking group errors"
  ERROR ::= 1
  WARNING ::= 2
  group-test-path := "$(directory.cwd)/group-test.toit"

  client.send-did-open --path=group-test-path --text="""
    import .ambiguous_a
    import .ambiguous_b
    main:
      foo
    """
  diagnostics = client.diagnostics-for --path=group-test-path
  expect-equals 1 diagnostics.size
  diagnostic := diagnostics.first
  expect-equals ERROR diagnostic["severity"]
  expect-equals 2 diagnostic["relatedInformation"].size

  client.send-did-open --path=group-test-path --text="""
    import .ambiguous_a
    import .ambiguous_b
    /** \$foo */
    main:
    """
  diagnostics = client.diagnostics-for --path=group-test-path
  expect-equals 1 diagnostics.size
  diagnostic = diagnostics.first
  expect-equals WARNING diagnostic["severity"]
  expect-equals 2 diagnostic["relatedInformation"].size

  response = client.send-request "toit/non_existing"  {:}
  expect (response.contains "code")
  UNKNOWN-ERROR-CODE ::= -32601
  expect-equals UNKNOWN-ERROR-CODE response["code"]

  // Check that diagnostics have newlines.
  print "Checking diagnostics have newlines"
  newline-path := "$(directory.cwd)/newline.toit"

  // The diagnostic here will have multiple lines, as it
  // explains how the 'foo' method could be called.
  client.send-did-open --path=newline-path --text="""
    foo x y:
    main:
      foo 1
    """
  diagnostics = client.diagnostics-for --path=newline-path
  expect-equals 1 diagnostics.size
  diagnostic = diagnostics.first
  expect (diagnostic["message"].contains "\n")
  expect-not (diagnostic["message"].ends-with "\n")
