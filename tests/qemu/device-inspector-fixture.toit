// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import system

class InspectorMarker:
  label/string
  values/List
  bytes/ByteArray
  promotion-payload/List

  constructor:
    label = "TOIT-DEVICE-INSPECTOR-FIXTURE-7f36a221"
    values = [0x1020_3040, 0x5060_7080, "heap marker", [1, 1, 2, 3, 5, 8]]
    bytes = ByteArray 4_096: | index |
      (index * 17 + 23) & 0xff
    // External ByteArray payload does not fill the copying heap. Keep enough
    // ordinary Toit objects live to cross its survivor threshold instead.
    promotion-payload = List 384: | index |
      [index, index + 1, index + 2, index + 3]

old-space-marker := InspectorMarker
wifi-resource-group/ByteArray? := null

main:
  marker := old-space-marker
  // QEMU does not emulate the ESP32-S3 radio, so esp_wifi_start never
  // completes. esp_wifi_init still initializes the driver and allocates its
  // buffers, which is the memory-accounting state this fixture needs.
  wifi-resource-group = wifi-init_ true
  print "DEVICE-INSPECTOR-WIFI-INITIALIZED"
  // Once the survivor threshold is crossed, these two collections age and
  // promote the still-live marker graph. The capture test verifies the result.
  system.process-stats --gc
  arm-inspector-checkpoints
  system.print-objects --marker="device-inspector-checkpoint" --gc
  print "DEVICE-INSPECTOR-READY"
  while marker.bytes[123] == ((123 * 17 + 23) & 0xff) and
      marker.promotion-payload[123][2] == 125:
    sleep --ms=1_000

arm-inspector-checkpoints -> none:
  #primitive.debug.vm-state-checkpoint-arm

wifi-init_ ap/bool -> ByteArray:
  #primitive.wifi.init
