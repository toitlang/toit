// Copyright (C) 2021 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

// The standard BLE provisioning demo for configuring Wi-Fi AP SSID and password

import encoding.hex
import esp32.provisioning

main:
  id := provisioning.get_mac_address[3..]
  service_name ::= "PROV_" + (hex.encode id)

  prov := provisioning.Provisioning.ble
      service_name
      provisioning.SECURITY0
  prov.start

  note ::= """
      Copy paste the below URL in a browser:\n\n\
      \
      https://espressif.github.io/esp-jumpstart/qrcode.html?data=\
      {"ver":"v1","name":"$(service_name)","transport":"ble", "security":0}"""
  print note

  prov.wait
