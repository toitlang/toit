// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ..ble-receive-close-pressure-test as fixture

main:
  print "DEVICE_RX_CLOSE_PRESSURE START heap=65536 handles=16 packets=32 ballast=64"
  fixture.run --heap-limit=(64 * 1024) --ballast-slots=4096 --ballast-size=64
  print "DEVICE_RX_CLOSE_PRESSURE COMPLETE"
