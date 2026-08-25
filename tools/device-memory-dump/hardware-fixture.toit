// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import system

class HardwareInspectorMarker:
  label/string
  values/List
  bytes/ByteArray
  promotion-payload/List

  constructor:
    label = "TOIT-HARDWARE-INSPECTOR-FIXTURE-9e3e5fa1"
    values = [0x1020_3040, 0x5060_7080, "heap marker", [1, 1, 2, 3, 5, 8]]
    bytes = ByteArray 4_096: | index |
      (index * 17 + 23) & 0xff
    promotion-payload = List 384: | index |
      [index, index + 1, index + 2, index + 3]

old-space-marker := HardwareInspectorMarker
wifi-resource-group/ByteArray? := null

main:
  marker := old-space-marker
  wifi-resource-group = wifi-init_ true
  print "DEVICE-INSPECTOR-HARDWARE-WIFI-INITIALIZED"
  system.process-stats --gc
  print "DEVICE-INSPECTOR-HARDWARE-READY"
  while marker.bytes[123] == ((123 * 17 + 23) & 0xff) and
      marker.promotion-payload[123][2] == 125:
    sleep --ms=1_000

wifi-init_ ap/bool -> ByteArray:
  #primitive.wifi.init
