// Copyright (C) 2021 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .lsp-client show LspClient run-client-test
import host.directory
import expect show *

main args:
  run-client-test args: test it

test client/LspClient:
  double-import-dir := "$directory.cwd/double_import"
  good-main := "$double-import-dir/project_with_good_lock/main.toit"
  bad-main := "$double-import-dir/project_with_bad_lock/main.toit"
  shared-file := "$double-import-dir/shared/shared.toit"

  // The shared file has errors when opened on its own.
  client.send-did-open --path=shared-file
  diagnostics := client.diagnostics-for --path=shared-file
  expect diagnostics.size > 0

  // The good directory has a package lock file that
  // leads to 0 errors.
  // However, the shared file continues to show the diagnostics of
  // it being analyzed in its own project.
  client.send-did-open --path=good-main
  diagnostics = client.diagnostics-for --path=good-main
  expect-equals 0 diagnostics.size
  diagnostics = client.diagnostics-for --path=shared-file
  expect diagnostics.size > 0

  // The bad directory has a package lock file that
  // leads to errors in the shared file again.
  // The LSP server must reverse-propagate that error to the good project.
  // (after all, the shared file has a changed external summary which might
  // have an impact on the good one).
  // When the good project reanalyzes its code, it will detect that the
  // shared file actually doesn't have an error. At this point, it must not
  // update the file's summary/diagnostics again, as this would lead to an
  // infinite recursion, requiring the bad project to be analyzed again...
  client.send-did-open --path=bad-main
  diagnostics = client.diagnostics-for --path=bad-main
  // The bad main itself doesn't have errors.
  expect-equals 0 diagnostics.size
  // The diagnostics of the shared file still is analyzed in its own project.
  diagnostics = client.diagnostics-for --path=shared-file
  expect diagnostics.size > 0
