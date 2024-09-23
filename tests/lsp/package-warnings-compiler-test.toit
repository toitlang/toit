// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .lsp-client show LspClient run-client-test
import expect show *
import host.directory
import host.file

main args:
  foo-path := "$directory.cwd/package-warnings/foo.toit"
  pkg1-path := "$directory.cwd/package-warnings/.packages/pkg1/src/pkg1.toit"

  expect (file.is-file foo-path)
  expect (file.is-file pkg1-path)

  2.repeat:
    should-report := it == 0
    pre-initializer := : | client/LspClient initialize-params/Map |
      client.configuration["reportPackageDiagnostics"] = should-report

    run-client-test args --pre-initialize=pre-initializer:
      test it foo-path pkg1-path --should-report=should-report

test client/LspClient foo-path/string pkg1-path/string --should-report/bool:
  client.send-did-open --path=foo-path
  diagnostics := client.diagnostics-for --path=pkg1-path
  if should-report:
    expect-equals 1 diagnostics.size
  else:
    expect-null diagnostics

  client.send-did-open --path=pkg1-path
  // When opened directly, the pkg1-path always has errors.
  diagnostics = client.diagnostics-for --path=pkg1-path
  expect-equals 1 diagnostics.size

  client.send-did-close --path=pkg1-path
  // When closed, the pkg1-path falls back to the original setting.
  diagnostics = client.diagnostics-for --path=pkg1-path
  expect-equals (should-report ? 1 : 0) diagnostics.size
