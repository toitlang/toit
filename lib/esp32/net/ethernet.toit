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
import net.udp
import net.tcp
import spi

import system.base.network show CloseableNetwork
import net.modules.tcp as tcp_module
import net.modules.udp as udp_module
import net.modules.dns as dns_module

MAC_CHIP_ESP32    ::= 0
MAC_CHIP_W5500    ::= 1
MAC_CHIP_OPENETH  ::= 2

PHY_CHIP_NONE     ::= 0
PHY_CHIP_IP101    ::= 1
PHY_CHIP_LAN8720  ::= 2
PHY_CHIP_DP83848  ::= 3

ETHERNET_CONNECT_TIMEOUT_  ::= Duration --s=10
ETHERNET_DHCP_TIMEOUT_     ::= Duration --s=16

ETHERNET_CONNECTED_    ::= 1 << 0
ETHERNET_DHCP_SUCCESS_ ::= 1 << 1
ETHERNET_DISCONNECTED_ ::= 1 << 2

ethernet_/EthernetDriver_? := null
ethernet_connecting_/monitor.Latch? := null

/**
Connects the Ethernet peripheral.

The $mac_chip must be one of $MAC_CHIP_ESP32 or $MAC_CHIP_W5500.
The $phy_chip must be one of $PHY_CHIP_NONE, $PHY_CHIP_IP101 or $PHY_CHIP_LAN8720.

# Olimex Gateway
The Olimex gateway needs an sdkconfig change:

``` diff
diff --git b/toolchains/esp32/sdkconfig a/toolchains/esp32/sdkconfig
index df798c8..fef8c8a 100644
--- b/toolchains/esp32/sdkconfig
+++ a/toolchains/esp32/sdkconfig
@@ -492,9 +492,10 @@ CONFIG_ETH_ENABLED=y
 CONFIG_ETH_USE_ESP32_EMAC=y
 CONFIG_ETH_PHY_INTERFACE_RMII=y
 # CONFIG_ETH_PHY_INTERFACE_MII is not set
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

After that, it can connect with:
```
  eth := ethernet.connect
      --mac_chip=ethernet.MAC_CHIP_ESP32
      --phy_chip=ethernet.PHY_CHIP_LAN8720
      --mac_mdc=gpio.Pin 23
      --mac_mdio=gpio.Pin 18
      --phy_addr=0
      --mac_spi_device=null
      --mac_int=null
```
*/
connect -> net.Interface
    --phy_chip/int
    --phy_addr/int=-1
    --phy_reset/gpio.Pin?=null
    --mac_chip/int
    --mac_mdc/gpio.Pin?
    --mac_mdio/gpio.Pin?
    --mac_spi_device/spi.Device?
    --mac_int/gpio.Pin?:
  if not ethernet_:
    if ethernet_connecting_:
      // If we're already connecting, we wait and see if that leads to
      // an exception. If it doesn't throw, then we continue to mark
      // ourselves as a user of the network.
      exception := ethernet_connecting_.get
      if exception: throw exception
    else:
      // We use a latch to coordinate the initial creation of the Ethernet
      // connection. We always set it to a value when leaving this path
      // and we always clear out the latch when we're done synchronizing.
      ethernet_connecting_ = monitor.Latch
      ethernet := EthernetDriver_
          --phy_chip=phy_chip
          --phy_addr=phy_addr
          --phy_reset=phy_reset
          --mac_chip=mac_chip
          --mac_mdc=mac_mdc
          --mac_mdio=mac_mdio
          --mac_spi_device=mac_spi_device
          --mac_int=mac_int
      try:
        with_timeout ETHERNET_CONNECT_TIMEOUT_: ethernet.connect
        with_timeout ETHERNET_DHCP_TIMEOUT_: ethernet.get_ip
        // Success: Register the Ethernet connection, tell anyone who is waiting
        // for it that the connection is ready to be used (no exception), and
        // go on to mark ourselves as a user of the Ethernet network.
        ethernet_ = ethernet
        ethernet_connecting_.set null
      finally: | is_exception exception |
        if is_exception:
          ethernet.close
          ethernet_connecting_.set exception.value
        ethernet_connecting_ = null

  return EthernetInterface_

class EthernetInterface_ extends CloseableNetwork implements net.Interface:
  static open_count_/int := 0
  open_/bool := true

  constructor:
    open_count_++

  name -> string:
    return "ethernet"

  resolve host/string -> List:
    with_ethernet_:
      return [dns_module.dns_lookup host]
    unreachable

  udp_open -> udp.Socket:
    return udp_open --port=null

  udp_open --port/int? -> udp.Socket:
    with_ethernet_:
      return udp_module.Socket "0.0.0.0" (port ? port : 0)
    unreachable

  tcp_connect host/string port/int -> tcp.Socket:
    ips := resolve host
    return tcp_connect
        net.SocketAddress ips[0] port

  tcp_connect address/net.SocketAddress -> tcp.Socket:
    with_ethernet_:
      result := tcp_module.TcpSocket
      result.connect address.ip.stringify address.port
      return result
    unreachable

  tcp_listen port/int -> tcp.ServerSocket:
    with_ethernet_:
      result := tcp_module.TcpServerSocket
      result.listen "0.0.0.0" port
      return result
    unreachable

  address -> net.IpAddress:
    with_ethernet_:
      return it.address
    unreachable

  is_closed -> bool:
    return not open_

  close_ -> none:
    if not open_: return
    open_ = false
    open_count_--
    if open_count_ > 0: return
    ethernet := ethernet_
    ethernet_ = null
    ethernet.close

  with_ethernet_ [block]:
    if not open_: throw "interface is closed"
    block.call ethernet_

class EthernetDriver_:
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
      if (state & ETHERNET_CONNECTED_) != 0:
        logger_.debug "connected"
        return
      else if (state & ETHERNET_DISCONNECTED_) != 0:
        logger_.warn "connect failed"
        close
        throw "CONNECT_FAILED"

  get_ip:
    resource := ethernet_setup_ip_ resource_group_
    res := monitor.ResourceState_ resource_group_ resource
    state := res.wait
    res.dispose
    if (state & ETHERNET_DHCP_SUCCESS_) != 0:
      ip := ethernet_get_ip_ resource
      logger_.debug "got ip" --tags={"ip": ip}
      return ip
    close
    throw "IP_ASSIGN_FAILED"

  rssi -> int?:
    return null

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
