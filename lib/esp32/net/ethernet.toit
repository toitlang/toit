// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/**
Network driver as a service for wired Ethernet on the ESP32.

See $EthernetServiceProvider for details.
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

/**
Service provider for networking via the Ethernet peripheral.

This provider must be installed before Ethernet networking can be used
  on the ESP32. The provider can be installed in a separate container
  or in the same container as the application.

# Example

An example of how to install the service provider in the same
  container:

``` toit
import gpio
import net.ethernet
import esp32.net.ethernet as esp32

main:
  power := gpio.Pin --output 12
  power.set 1
  // sleep --ms=1000
  provider := esp32.EthernetServiceProvider
      --phy_chip=esp32.PHY_CHIP_LAN8720
      --phy_address=0
      --mac_chip=esp32.MAC_CHIP_ESP32
      --mac_mdc=gpio.Pin 23
      --mac_mdio=gpio.Pin 18
      --mac_spi_device=null
      --mac_interrupt=null
  provider.install
  network := ethernet.open
  // Use the network.
  network.close
  provider.uninstall
  power.close
```

# Olimex Gateway
The Olimex gateway needs an SDK config change:

In `make menuconfig` search for the setting
  `CONFIG_ETH_RMII_CLK_OUTPUT` and set it to true.
  That should disable `CONFIG_ETH_RMII_CLK_INPUT` and
  set `CONFIG_ETH_RMII_CLK_OUT_GPIO` to 17 (the default).

``` diff
--- b/toolchains/esp32/sdkconfig
+++ a/toolchains/esp32/sdkconfig
@@ -505,9 +505,10 @@
 CONFIG_ETH_ENABLED=y
 CONFIG_ETH_USE_ESP32_EMAC=y
 CONFIG_ETH_PHY_INTERFACE_RMII=y
-CONFIG_ETH_RMII_CLK_INPUT=y
-# CONFIG_ETH_RMII_CLK_OUTPUT is not set
-CONFIG_ETH_RMII_CLK_IN_GPIO=0
+# CONFIG_ETH_RMII_CLK_INPUT is not set
+CONFIG_ETH_RMII_CLK_OUTPUT=y
+# CONFIG_ETH_RMII_CLK_OUTPUT_GPIO0 is not set
+CONFIG_ETH_RMII_CLK_OUT_GPIO=17
 CONFIG_ETH_DMA_BUFFER_SIZE=512
 CONFIG_ETH_DMA_RX_BUFFER_NUM=10
 CONFIG_ETH_DMA_TX_BUFFER_NUM=10
```
*/
class EthernetServiceProvider extends ServiceProvider implements ServiceHandler:
  state_/NetworkState ::= NetworkState
  create_resource_group_/Lambda

  /**
  The $mac_chip must be one of $MAC_CHIP_ESP32 or $MAC_CHIP_W5500.
  The $phy_chip must be one of $PHY_CHIP_NONE, $PHY_CHIP_IP101 or $PHY_CHIP_LAN8720.
  */
  constructor
      --phy_chip/int
      --phy_address/int=-1
      --phy_reset/gpio.Pin?=null
      --mac_chip/int
      --mac_mdc/gpio.Pin?
      --mac_mdio/gpio.Pin?
      --mac_spi_device/spi.Device?
      --mac_interrupt/gpio.Pin?:
    if mac_chip == MAC_CHIP_ESP32 or mac_chip == MAC_CHIP_OPENETH:
      create_resource_group_ = :: ethernet_init_esp32_
          mac_chip
          phy_chip
          phy_address
          phy_reset ? phy_reset.num : -1
          mac_mdc ? mac_mdc.num : -1
          mac_mdio ? mac_mdio.num : -1
    else if phy_chip != PHY_CHIP_NONE:
      throw "unexpected PHY chip selection"
    else:
      create_resource_group_ = :: ethernet_init_spi_
          mac_chip
          (mac_spi_device as spi.Device_).device_
          mac_interrupt.num
    super "system/ethernet/esp32" --major=0 --minor=1
        --tags=[NetworkService.TAG_ETHERNET]
    provides EthernetService.SELECTOR --handler=this

  handle index/int arguments/any --gid/int --client/int -> any:
    if index == EthernetService.CONNECT_INDEX:
      return connect client
    if index == NetworkService.ADDRESS_INDEX:
      network := (resource client arguments) as NetworkResource
      return address network
    unreachable

  connect client/int -> List:
    state_.up: EthernetModule_ this create_resource_group_
    try:
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
    return (state_.module as EthernetModule_).address.to_byte_array

  on_module_closed module/EthernetModule_ -> none:
    critical_do:
      resources_do: | resource/NetworkResource |
        if not resource.is_closed:
          resource.notify_ NetworkService.NOTIFY_CLOSED --close

class EthernetModule_ implements NetworkModule:
  static ETHERNET_CONNECT_TIMEOUT ::= Duration --s=10
  static ETHERNET_DHCP_TIMEOUT    ::= Duration --s=16

  static ETHERNET_CONNECTED    ::= 1 << 0
  static ETHERNET_DHCP_SUCCESS ::= 1 << 1
  static ETHERNET_DISCONNECTED ::= 1 << 2

  logger_/log.Logger ::= log.default.with_name "ethernet"
  service/EthernetServiceProvider

  resource_group_ := ?
  address_/net.IpAddress? := null

  constructor .service create_resource_group/Lambda:
    resource_group_ = create_resource_group.call

  address -> net.IpAddress:
    return address_

  connect -> none:
    with_timeout ETHERNET_CONNECT_TIMEOUT: wait_for_connected_
    with_timeout ETHERNET_DHCP_TIMEOUT: wait_for_dhcp_ip_address_

  disconnect -> none:
    if not resource_group_: return
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
      if (state & ETHERNET_CONNECTED) != 0:
        logger_.debug "connected"
        return
      else if (state & ETHERNET_DISCONNECTED) != 0:
        logger_.warn "connect failed"
        throw "CONNECT_FAILED"

  wait_for_dhcp_ip_address_ -> none:
    resource := ethernet_setup_ip_ resource_group_
    ip_events := monitor.ResourceState_ resource_group_ resource
    state := ip_events.wait
    ip_events.dispose
    if (state & ETHERNET_DHCP_SUCCESS) == 0: throw "IP_ASSIGN_FAILED"
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
