// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.bond-flash
import expect show *
import system

// Dedicated raw-record namespace; no bonds or radio are used.
main:
  records := bond-flash.FlashRecords "toit.test/nvs-read-001"
  count := 0
  try:
    records.remove "blob"
    expect-null (records.read "blob")
    [0, 1, 98, 512, 1024, 98, 1, 0].do: | length/int |
      value := ByteArray length --initial=42
      records.write "blob" value
      received := records.read "blob"
      expect-equals value received
      system.process-stats --gc
      expect-equals value received
      count++
    records.close
    records = bond-flash.FlashRecords "toit.test/nvs-read-001"
    expect-equals #[] (records.read "blob")
    records.remove "blob"
    expect-null (records.read "blob")
  finally:
    records.close
  print "FLASH_RECORDS COMPLETE writes=$count reads=11 gcs=8"
