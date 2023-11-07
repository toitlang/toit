// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

// This example illustrates how to scan for WiFi access points.

import net.wifi

SCAN-CHANNELS := #[1, 2, 3, 4, 5, 6, 7]

main:
  access-points := wifi.scan
      SCAN-CHANNELS
      --period-per-channel-ms=120
  if access-points.size == 0:
    print "Scan done, but no APs found"
    return

  print """
      $(%-32s "SSID") $(%-18s "BSSID") \
      $(%-6s "RSSI") $(%-8s "Channel") \
      $(%-8s "Author")\n"""

  access-points.do: | ap/wifi.AccessPoint |
    print """
        $(%-32s ap.ssid) $(%-18s ap.bssid-name) \
        $(%-6s ap.rssi) $(%-8s ap.channel) \
        $(%-8s ap.authmode-name)"""
