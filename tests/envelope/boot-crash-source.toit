// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import host.file
import host.os
import system.firmware
import system.storage
import .exit-codes

main:
  test-dir := os.env["BOOT_TEST_DIR"]
  if file.is-file "$test-dir/mark":
    second-call
  else:
    first-call test-dir

with-region [block]:
  region := storage.Region.open --flash "toitlang.org/envelope-test-region" --capacity=100
  block.call region
  region.close

HELLO ::= "hello world"

first-call test-dir/string:
  print "first call"
  file.write-contents --path="$test-dir/mark" "first"

  with-region: | region/storage.Region |
    region.write --at=0 HELLO

  // Exit with a crash.
  exit 1

second-call:
  with-region: | region/storage.Region |
    existing := region.read --from=0 --to=HELLO.size
    if existing == HELLO:
      print "Test failed"
    else:
      // The flash was correctly cleared after the crash.
      print "Test succeeded"
    exit EXIT-CODE-STOP
