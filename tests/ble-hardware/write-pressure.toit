// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ..ble-write-pressure-test as writes

// The sole application on a dedicated board; no radio or NVS access.
main:
  set-max-heap-size_ (64 * 1024)
  with-timeout --ms=300_000:
    print "DEVICE_WRITE_PRESSURE START heap=65536"
    ["write", "command", "execute", "cccd", "cccd-execute"].do:
      writes.run it --released-offset=0 --ballast-size=(it == "cccd" ? 8 : 64)
    print "DEVICE_WRITE_PRESSURE COMPLETE rounds=320"
