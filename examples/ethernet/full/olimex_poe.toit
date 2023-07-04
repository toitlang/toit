// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

/**
Example of a custom Ethernet service provider for the ESP32.

The Olimex PoE board has a power pin that needs to be turned on before the
  Ethernet chip can be used. This example shows how to create a custom
  Ethernet service provider that turns on the power pin before connecting
  and turns it off again when the module is closed.

This program should be installed as separate container. For example with
  `jag container install eth eth.toit`.
*/

import gpio
import esp32.net.ethernet as esp32

class OlimexPoeProvider extends esp32.EthernetServiceProvider:
  power_/gpio.Pin? := null
  connected_clients_/int := 0

  constructor:
    super
        --phy_chip=esp32.PHY_CHIP_LAN8720
        --phy_address=0
        --mac_chip=esp32.MAC_CHIP_ESP32
        --mac_mdc=gpio.Pin 23
        --mac_mdio=gpio.Pin 18
        --mac_spi_device=null
        --mac_interrupt=null

  connect client/int -> List:
    try:
      power_ = gpio.Pin --output 12
      power_.set 1
      return super client
    finally: | is_exception _ |
      if is_exception and power_:
        // If we don't succeed here, turn the power off.
        critical_do:
          power_.close
          power_ = null

  on_opened client:
    super client
    connected_clients_++
    if connected_clients_ == 1:
      power_ = gpio.Pin --output 12
      power_.set 1

  on_closed client:
    super client
    connected_clients_--
    if connected_clients_ == 0 and power_:
      critical_do:
        power_.close
        power_ = null
