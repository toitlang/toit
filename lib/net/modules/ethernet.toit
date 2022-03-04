// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import log
import monitor
import gpio
import spi

TOIT_ETHERNET_CONNECTED_    ::= 1 << 0
TOIT_ETHERNET_DHCP_SUCCESS_ ::= 1 << 1
TOIT_ETHERNET_DISCONNECTED_ ::= 1 << 2

MAC_CHIP_ESP32    ::= 0
MAC_CHIP_W5500    ::= 1

PHY_CHIP_NONE     ::= 0
PHY_CHIP_IP101    ::= 1
PHY_CHIP_LAN8720  ::= 2

class Ethernet:
  logger_/log.Logger ::= log.default.with_name "ethernet"

  resource_group_ := null

  constructor
      --phy_chip/int
      --phy_addr/int=-1
      --phy_reset/gpio.Pin?=null
      --mac_chip/int
      --mac_mdc/gpio.Pin?
      --mac_mdio/gpio.Pin?
      --mac_spi_device/spi.Device?
      --mac_int/gpio.Pin?:

    if mac_chip == MAC_CHIP_ESP32:
      resource_group_ = ethernet_init_esp32_
        phy_chip
        phy_addr
        (phy_reset ? phy_reset.num : -1)
        mac_mdc.num
        mac_mdio.num
    else:
      if phy_chip != PHY_CHIP_NONE: throw "unexpected PHY chip selection"
      resource_group_ = ethernet_init_spi_
        mac_chip
        (mac_spi_device as spi.Device_).device_
        mac_int.num

  close:
    if resource_group_:
      ethernet_close_ resource_group_
      resource_group_ = null

  connect:
    logger_.debug "connecting"
    while true:
      resource := ethernet_connect_ resource_group_
      res := monitor.ResourceState_ resource_group_ resource
      state := res.wait
      res.dispose
      if (state & TOIT_ETHERNET_CONNECTED_) != 0:
        logger_.debug "connected"
        return
      else if (state & TOIT_ETHERNET_DISCONNECTED_) != 0:
        logger_.warn "connect failed"
        close
        throw "CONNECT_FAILED"

  get_ip:
    resource := ethernet_setup_ip_ resource_group_
    res := monitor.ResourceState_ resource_group_ resource
    state := res.wait
    res.dispose
    if (state & TOIT_ETHERNET_DHCP_SUCCESS_) != 0:
      ip := ethernet_get_ip_ resource
      logger_.debug "got ip" --tags={"ip": ip}
      return ip
    close
    throw "IP_ASSIGN_FAILED"

  rssi -> int?:
    return null

ethernet_init_esp32_ phy_chip/int phy_addr/int phy_reset_num/int mac_mdc_num/int mac_mdio_num/int:
  #primitive.ethernet.init_esp32

ethernet_init_spi_ mac_chip/int spi_device int_num/int:
  #primitive.ethernet.init_spi

ethernet_close_ resource_group:
  #primitive.ethernet.close

ethernet_connect_ resource_group:
  #primitive.ethernet.connect

ethernet_setup_ip_ resource_group:
  #primitive.ethernet.setup_ip

ethernet_disconnect_ resource_group resource:
  #primitive.ethernet.disconnect

ethernet_get_ip_ resource:
  #primitive.ethernet.get_ip
