// Copyright (C) 2021 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .lsp-client show LspClient run-client-test
import expect show *
import host.directory
import host.file

main args:
  root := "$directory.cwd/project_root"
  foo-dir := "$root/.packages/foo/1.0.0"
  foo-package-lock := "$foo-dir/package.lock"
  foo-entry := "$foo-dir/src/foo.toit"

  expect (file.is-directory foo-dir)
  expect (file.is-file foo-package-lock)
  expect (file.is-file foo-entry)

  pre-initializer := : | client/LspClient initialize-params/Map |
    initialize-params["rootUri"]=(client.to-uri root)

  run-client-test args --pre-initialize=pre-initializer:
    test it foo-entry

test client/LspClient foo-path/string:
  // The foo-path has no errors, but only because it's using the package.lock
  // file of the project root.
  client.send-did-open --path=foo-path
  diagnostics := client.diagnostics-for --path=foo-path
  expect-equals 0 diagnostics.size


