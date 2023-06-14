// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/**
Network driver for wired Ethernet.
*/

import esp32
import gpio
import log
import monitor
import net
import net.ethernet
import spi

import system.api.ethernet show EthernetService
import system.api.network show NetworkService
import system.services show ServiceProvider ServiceHandler
import system.base.network show NetworkModule NetworkState NetworkResource

MAC_CHIP_ESP32    ::= 0
MAC_CHIP_W5500    ::= 1
MAC_CHIP_OPENETH  ::= 2

PHY_CHIP_NONE     ::= 0
PHY_CHIP_IP101    ::= 1
PHY_CHIP_LAN8720  ::= 2
PHY_CHIP_DP83848  ::= 3

CONFIG_PHY_CHIP    /string ::= "ethernet.phy.chip"
CONFIG_PHY_ADDRESS /string ::= "ethernet.phy.address"
CONFIG_PHY_RESET   /string ::= "ethernet.phy.reset"

CONFIG_MAC_CHIP      /string ::= "ethernet.mac.chip"
CONFIG_MAC_MDC       /string ::= "ethernet.mac.mdc"
CONFIG_MAC_MDIO      /string ::= "ethernet.mac.mdio"
CONFIG_MAC_INTERRUPT /string ::= "ethernet.mac.interrupt"

CONFIG_MAC_SPI_CS           /string ::= "ethernet.mac.spi.cs"
CONFIG_MAC_SPI_DC           /string ::= "ethernet.mac.spi.dc"
CONFIG_MAC_SPI_FREQUENCY    /string ::= "ethernet.mac.spi.frequency"
CONFIG_MAC_SPI_MODE         /string ::= "ethernet.mac.spi.mode"
CONFIG_MAC_SPI_ADDRESS_BITS /string ::= "ethernet.mac.spi.address.bits"
CONFIG_MAC_SPI_COMMAND_BITS /string ::= "ethernet.mac.spi.command.bits"

ETHERNET_CONNECT_TIMEOUT_  ::= Duration --s=10
ETHERNET_DHCP_TIMEOUT_     ::= Duration --s=16

ETHERNET_CONNECTED_    ::= 1 << 0
ETHERNET_DHCP_SUCCESS_ ::= 1 << 1
ETHERNET_DISCONNECTED_ ::= 1 << 2

class EthernetServiceProvider extends ServiceProvider
    implements ServiceHandler:
  state_/NetworkState ::= NetworkState

  constructor:
    super "system/ethernet/esp32" --major=0 --minor=1
        --tags=[NetworkService.TAG_ETHERNET]
    provides EthernetService.SELECTOR --handler=this

  handle index/int arguments/any --gid/int --client/int -> any:
    if index == EthernetService.CONNECT_INDEX:
      return connect client arguments
    if index == NetworkService.ADDRESS_INDEX:
      network := (resource client arguments) as NetworkResource
      return address network
    unreachable

  connect client/int config/Map -> List:
    // TODO(kasper): Parse the configuration.
    phy_chip/int := config[ethernet.CONFIG_PHY_CHIP]
    phy_addr/int? := config.get ethernet.CONFIG_PHY_ADDRESS
    phy_reset/gpio.Pin? := null
    mac_chip/int := config[ethernet.CONFIG_MAC_CHIP]
    mac_mdc/gpio.Pin? := null
    mac_mdio/gpio.Pin? := null
    mac_spi/spi.Device? := null
    mac_interrupt/gpio.Pin? := null

    module ::= (state_.up: EthernetModule this) as EthernetModule
    try:
      // TODO(kasper): We should verify that the configuration
      // of the ethernet module we got matches the one we requested.
      resource := NetworkResource this client state_ --notifiable
      return [
        resource.serialize_for_rpc,
        NetworkService.PROXY_ADDRESS,
        "ethernet"
      ]
    finally: | is_exception exception |
      // If we're not returning a network resource to the client, we
      // must take care to decrement the usage count correctly.
      if is_exception: state_.down

  address resource/NetworkResource -> ByteArray:
    return (state_.module as EthernetModule).address.to_byte_array

  on_module_closed module/EthernetModule -> none:
    critical_do:
      resources_do: | resource/NetworkResource |
        if not resource.is_closed:
          resource.notify_ NetworkService.NOTIFY_CLOSED --close

class EthernetModule implements NetworkModule:
  logger_/log.Logger ::= log.default.with_name "ethernet"
  service/EthernetServiceProvider

  resource_group_ := ?
  address_/net.IpAddress? := null

  constructor .service
      --phy_chip/int
      --phy_addr/int=-1
      --phy_reset/gpio.Pin?=null
      --mac_chip/int
      --mac_mdc/gpio.Pin?
      --mac_mdio/gpio.Pin?
      --mac_spi_device/spi.Device?
      --mac_int/gpio.Pin?:
    if mac_chip == MAC_CHIP_ESP32 or mac_chip == MAC_CHIP_OPENETH:
      resource_group_ = ethernet_init_esp32_
        mac_chip
        phy_chip
        phy_addr
        (phy_reset ? phy_reset.num : -1)
        (mac_mdc ? mac_mdc.num : -1)
        (mac_mdio ? mac_mdio.num : -1)
    else:
      if phy_chip != PHY_CHIP_NONE: throw "unexpected PHY chip selection"
      resource_group_ = ethernet_init_spi_
        mac_chip
        (mac_spi_device as spi.Device_).device_
        mac_int.num

  address -> net.IpAddress:
    return address_

  connect -> none:
    with_timeout ETHERNET_CONNECT_TIMEOUT_: wait_for_connected_
    with_timeout ETHERNET_DHCP_TIMEOUT_: wait_for_dhcp_ip_address_

  disconnect -> none:
    if not resource_group_:
      return

    logger_.debug "closing"
    ethernet_close_ resource_group_
    resource_group_ = null
    address_ = null
    service.on_module_closed this

  wait_for_connected_ -> none:
    logger_.debug "connecting"
    while true:
      resource := ethernet_connect_ resource_group_
      ethernet_events := monitor.ResourceState_ resource_group_ resource
      state := ethernet_events.wait
      ethernet_events.dispose
      if (state & ETHERNET_CONNECTED_) != 0:
        logger_.debug "connected"
        return
      else if (state & ETHERNET_DISCONNECTED_) != 0:
        logger_.warn "connect failed"
        throw "CONNECT_FAILED"

  wait_for_dhcp_ip_address_ -> none:
    resource := ethernet_setup_ip_ resource_group_
    ip_events := monitor.ResourceState_ resource_group_ resource
    state := ip_events.wait
    ip_events.dispose
    if (state & ETHERNET_DHCP_SUCCESS_) == 0: throw "IP_ASSIGN_FAILED"
    ip := ethernet_get_ip_ resource
    address_ = net.IpAddress ip
    logger_.info "network address dynamically assigned through dhcp" --tags={"ip": address_}

ethernet_init_esp32_ mac_chip/int phy_chip/int phy_addr/int phy_reset_num/int mac_mdc_num/int mac_mdio_num/int:
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
