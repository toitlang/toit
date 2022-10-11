// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import provisioning

main:
  service := provisioning.BLEService
  if service.is_provisioned:
    print "Device is provisioned and connect to AP."
    service.connect_to_ap
  else:
    print "Start provisioning"

    service_port := "ble"
    service_version ::= "v1"
    service_name ::= "PROV_" + service.get_mac_addr_string[6..12]
    service_pop ::= "abcd1234"
    customer_uuid ::= #[0xb4, 0xdf, 0x5a, 0x1c, 0x3f, 0x6b, 0xf4, 0xbf,
                        0xea, 0x4a, 0x82, 0x03, 0x04, 0x90, 0x1a, 0x02]
 
    service.start --name=service_name
                  --pop=service_pop
                  --uuid=customer_uuid

    service_data ::= """
        {\"ver\":\"$service_version\",\
        \"name\":\"$service_name\",\
        \"pop\":\"$service_pop\",\
        \"transport\":\"$service_port\"}\
        """

    print "Scan this QR code from the provisioning application for Provisioning."
    service.qrcode_print_string --data=service_data

    print "If QR code is not visible, copy paste the below URL in a browser."
    print "https://espressif.github.io/esp-jumpstart/qrcode.html?data=$service_data"

  if service.wait_for_done --min=10:
    print "Provisioning is done"
    print "IP Address: $service.get_ip_addr_string"
  else:
    print "Provisioning is timeout"
