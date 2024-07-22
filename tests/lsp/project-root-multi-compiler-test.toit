// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .lsp-client show LspClient run-client-test
import expect show *
import host.directory
import host.file

main args:
  /*
  Setup:
    p1 depends on p2.
    p2 depends on *a* p3.
    p1's lock-file resolves p3 to p3-bad.
    p2's lock-file resolves p3 to p3-good.
    p3-good has no errors.
    p3-bad has a function marked as deprecated. p2 shows a warning if
      it depends on p3-bad.

    The LSP should always use the lock-file from the project root of a specific
      file. This means that even when analyzing p1, it should still use the
      lock-file of p2 for the analysis of p2/p2.toit.
  */

  test-root := "$directory.cwd/project-root-multi"
  p1-dir := "$test-root/p1"
  p2-dir := "$test-root/p2"
  p3-good-dir := "$test-root/p3-good"
  p3-bad-dir := "$test-root/p3-bad"

  p1-path := "$p1-dir/src/p1.toit"
  p2-path := "$p2-dir/src/p2.toit"
  p3-good-path := "$p3-good-dir/src/p3.toit"
  p3-bad-path := "$p3-bad-dir/src/p3.toit"

  expect (file.is-directory p1-dir)
  expect (file.is-directory p2-dir)
  expect (file.is-directory p3-good-dir)
  expect (file.is-directory p3-bad-dir)
  expect (file.is-file p1-path)
  expect (file.is-file p2-path)
  expect (file.is-file p3-good-path)
  expect (file.is-file p3-bad-path)

  run-client-test args:
    test it p1-path p2-path p3-good-path p3-bad-path

test client/LspClient p1-path/string p2-path/string p3-good-path/string p3-bad-path/string:
  client.send-did-open --path=p1-path
  diagnostics := client.diagnostics-for --path=p1-path
  // p1 never has errors or warnings.
  expect-equals 0 diagnostics.size
  // No warning for p2 either.
  diagnostics = client.diagnostics-for --path=p2-path

  // Analyzing p2 directly also doesn't lead to an error/warning.
  client.send-did-open --path=p2-path
  diagnostics = client.diagnostics-for --path=p2-path
  expect-equals 0 diagnostics.size

  // If we change p3-good to p3-bad, we should get a warning.
  p3-bad-content := file.read-content p3-bad-path

  client.send-did-open --path=p3-good-path
  diagnostics = client.diagnostics-for --path=p2-path
  expect-equals 0 diagnostics.size

  client.send-did-change --path=p3-good-path p3-bad-content.to-string
  // Now we should get a warning.
  diagnostics = client.diagnostics-for --path=p2-path
  expect-equals 1 diagnostics.size
