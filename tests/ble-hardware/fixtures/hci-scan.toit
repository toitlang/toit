// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.hci
import ble.experimental.linux
import ble.experimental.scanning
import encoding.hex
import uuid

main args/List:
  if not 1 <= args.size <= 2:
    throw "Usage: hci-scan.toit <adapter index> [128-bit service UUID]"
  service := args.size == 2 ? (uuid.Uuid.parse args[1]).to-byte-array.reverse : null
  controller := hci.Controller (linux.LinuxTransport (int.parse args[0]))
  try:
    hci.initialize controller
    error := catch:
      with-timeout --ms=10_000:
        scanning.scan controller --active: | report |
          if service and not (report.has-service service): continue.scan true
          print "address=$(hex.encode report.address.reverse) type=$(report.address-type) rssi=$(report.rssi) data=$(hex.encode report.data)"
          // With a filter, stop at the first matching service advertisement.
          not service
    if error and error != DEADLINE-EXCEEDED-ERROR: throw error
  finally:
    controller.close
