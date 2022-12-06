// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

// This example illustrates how to connect to designated WiFi access point and
// get its information.

import net.wifi

USER_SSID ::= "myssid"
USER_PASSWORD ::= "mypassword"

main:
  connection := wifi.open
      --ssid=USER_SSID
      --password=USER_PASSWORD
  
  ap := connection.get_ap_info

  print """
      $(%-32s "SSID") $(%-18s "BSSID") \
      $(%-6s "RSSI") $(%-8s "Channel") \
      $(%-8s "Author")\n"""

  print """
      $(%-32s ap.ssid) $(%-18s ap.bssid_name) \
      $(%-6s ap.rssi) $(%-8s ap.channel) \
      $(%-8s ap.authmode_name)"""
