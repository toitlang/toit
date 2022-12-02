// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

// The standard BLE peripheral demo for simulating a heart rate monitor.

import net.wifi

SCAN_CHANNELS := #[1, 2, 3, 4, 5, 6, 7]

main:
  ap_list := wifi.scan
      SCAN_CHANNELS
      --period_per_channel_ms=120
  if ap_list.size == 0:
    throw "Scan done, but no AP is found"

  print """
      $(%-32s "SSID") $(%-18s "BSSID") \
      $(%-6s "RSSI") $(%-8s "Channel") \
      $(%-8s "Author")\n"""

  ap_list.do:
    ap := it as wifi.AccessPoint
    print """
        $(%-32s ap.ssid) $(%-18s ap.bssid_name) \
        $(%-6s ap.rssi) $(%-8s ap.channel) \
        $(%-8s ap.authmode_name)"""
