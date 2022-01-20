// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import .lsp_client show LspClient run_client_test
import expect show *
import host.directory
import host.file

main args:
  root := "$directory.cwd/project_root"
  foo_dir := "$root/.packages/foo/1.0.0"
  foo_package_lock := "$foo_dir/package.lock"
  foo_entry := "$foo_dir/src/foo.toit"

  expect (file.is_directory foo_dir)
  expect (file.is_file foo_package_lock)
  expect (file.is_file foo_entry)

  pre_initializer := : | client/LspClient initialize_params/Map |
    initialize_params["rootUri"]=(client.to_uri root)

  run_client_test args --pre_initialize=pre_initializer:
    test it foo_entry
  run_client_test --use_toitlsp args --pre_initialize=pre_initializer:
    test it foo_entry

test client/LspClient foo_path/string:
  // The foo-path has no errors, but only because it's using the package.lock
  // file of the project root.
  client.send_did_open --path=foo_path
  diagnostics := client.diagnostics_for --path=foo_path
  expect_equals 0 diagnostics.size


