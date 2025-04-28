// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import system.storage
import .exit-codes

main:
  region := storage.Region.open --flash "toitlang.org/envelope-test-region" --capacity=100
  bucket := storage.Bucket.open --flash "toitlang.org/envelope-test-bucket"

  hello := "hello world"
  hello-bytes := hello.to-byte-array
  existing-region := region.read --from=0 --to=hello-bytes.size
  existing-bucket := bucket.get "hello"
  if existing-region != hello-bytes or existing-bucket != "world":
    // We just assume that they haven't been written yet.
    region.write --at=0 hello
    bucket["hello"] = "world"
    region.close
    bucket.close
    // Exit with a non-stopping exit code, which will restart this container immediately.
    exit 0

  print "Test succeeded"
  exit EXIT-CODE-STOP
