// Copyright (C) 2021 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .lsp_client show LspClient run_client_test
import host.directory
import expect show *

main args:
  run_client_test --use_toitlsp args: test it
  run_client_test args: test it

test client/LspClient:
  double_import_dir := "$directory.cwd/double_import"
  good_main := "$double_import_dir/project_with_good_lock/main.toit"
  bad_main := "$double_import_dir/project_with_bad_lock/main.toit"
  shared_file := "$double_import_dir/shared/shared.toit"

  // The shared file has errors when opened on its own.
  client.send_did_open --path=shared_file
  diagnostics := client.diagnostics_for --path=shared_file
  expect diagnostics.size > 0

  // The good directory has a package lock file that
  // leads to 0 errors.
  client.send_did_open --path=good_main
  diagnostics = client.diagnostics_for --path=good_main
  expect_equals 0 diagnostics.size
  diagnostics = client.diagnostics_for --path=shared_file
  expect_equals 0 diagnostics.size

  // The bad directory has a package lock file that
  // leads to errors in the shared file again.
  // The LSP server must reverse-propagate that error to the good project.
  // (after all, the shared file has a changed external summary which might
  // have an impact on the good one).
  // When the good project reanalyzes its code, it will detect that the
  // shared file actually doesn't have an error. At this point, it must not
  // update the file's summary/diagnostics again, as this would lead to an
  // infinite recursion, requiring the bad project to be analyzed again...
  client.send_did_open --path=bad_main
  diagnostics = client.diagnostics_for --path=bad_main
  // The bad main itself doesn't have errors.
  expect_equals 0 diagnostics.size
  // However, the diagnostics of the shared file has
  // errors, as the package lock of the bad directory leads to errors there.
  diagnostics = client.diagnostics_for --path=shared_file
  expect diagnostics.size > 0
