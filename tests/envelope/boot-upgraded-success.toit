// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import system.firmware
import host.file
import host.os
import .exit-codes

main:
  print "hello from updated firmware!"
  print "validation is $(firmware.is-validation-pending ? "" : "not ")pending"
  print "can $(firmware.is-rollback-possible ? "" : "not ")rollback"

  test-dir := os.env["BOOT_TEST_DIR"]
  if file.is-file "$test-dir/mark":
    print "exiting"
    exit EXIT-CODE-STOP

  print "validating"
  firmware.validate
  file.write-contents --path="$test-dir/mark" "done"
  exit (int.parse os.env["BOOT_EXIT_CODE"])
