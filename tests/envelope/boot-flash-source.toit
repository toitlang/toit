// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import system.storage
import .exit-codes

main:
  region := storage.Region.open --flash "toitlang.org/envelope-test" --capacity=100
  hello-bytes := "hello world".to-byte-array
  existing := region.read --from=0 --to=hello-bytes.size
  if existing != hello-bytes:
    region.write --from=0 hello-bytes
    region.close
    exit 0

  print "Test succeeded"
  exit EXIT-CODE-STOP
