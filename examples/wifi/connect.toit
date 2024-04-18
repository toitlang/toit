// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

// This example illustrates how to connect to designated WiFi access point and
// get its information.

import net.wifi

USER-SSID ::= "myssid"
USER-PASSWORD ::= "mypassword"

main:
  connection := wifi.open
      --ssid=USER-SSID
      --password=USER-PASSWORD
  
  ap := connection.access-point

  print """
      $(%-32s "SSID") $(%-18s "BSSID") \
      $(%-6s "RSSI") $(%-8s "Channel") \
      $(%-8s "Author")\n"""

  print """
      $(%-32s ap.ssid) $(%-18s ap.bssid-name) \
      $(%-6s ap.rssi) $(%-8s ap.channel) \
      $(%-8s ap.authmode-name)"""
