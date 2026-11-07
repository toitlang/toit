// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
import expect show *
import system.storage

main arguments/List:
  bucket := storage.Bucket.open --flash "storage-recovery-test"
  try:
    operation := arguments[0]
    value := int.parse arguments[1]
    if operation == "write":
      bucket["value"] = ByteArray 8193 --initial=value
    else if operation == "read":
      expect-equals (ByteArray 8193 --initial=value) bucket["value"]
    else if operation == "remove":
      bucket.remove "value"
    else if operation == "empty":
      expect-equals null (bucket.get "value")
    else:
      throw "Unknown operation"
    print "PASS $operation $value"
  finally:
    bucket.close
