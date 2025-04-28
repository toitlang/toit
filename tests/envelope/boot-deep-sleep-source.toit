// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import host.file
import host.os
import .exit-codes

main:
  test-dir := os.env["BOOT_TEST_DIR"]
  if file.is-file "$test-dir/mark":
    print "Test succeeded"
    exit EXIT-CODE_STOP
  file.write-contents --path="$test-dir/mark" "first"
  __deep_sleep__ 20  // Sleep 20 ms.
