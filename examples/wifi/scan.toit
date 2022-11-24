// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

// The standard BLE peripheral demo for simulating a heart rate monitor.

import net.wifi
import encoding.hex

SCAN_CHANNELS := #[1, 2, 3, 4, 5, 6, 7]

main:
  ap_list := wifi.scan
      SCAN_CHANNELS
      --period_per_channel=1000

  print """
      $(%-32s "SSID") $(%-18s "BSSID") \
      $(%-6s "RSSI") $(%-8s "Channel") \
      $(%-8s "Author")\n"""

  ap_list.do:
    ssid := it[wifi.SCAN_AP_SSID]
    bssid := it[wifi.SCAN_AP_BSSID]
    rssi := it[wifi.SCAN_AP_RSSI]
    authmode := it[wifi.SCAN_AP_AUTHMODE]
    channel := it[wifi.SCAN_AP_CHANNEL]

    automode_name := wifi.wifi_authmode_name authmode
    bssid_desc := """
        $(%02x bssid[0]):$(%02x bssid[1]):$(%02x bssid[2]):\
        $(%02x bssid[3]):$(%02x bssid[4]):$(%02x bssid[5])"""

    print """
        $(%-32s ssid) $(%-18s bssid_desc) \
        $(%-6s rssi) $(%-8s channel) \
        $(%-8s automode_name)"""
