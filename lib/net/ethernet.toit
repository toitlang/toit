// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

/**
Network driver for wired Ethernet.
*/

import gpio
import monitor
import net
import net.udp
import net.tcp
import spi

import .modules.ethernet as ethernet
import .modules.ethernet show
    MAC_CHIP_ESP32 MAC_CHIP_W5500
    PHY_CHIP_NONE PHY_CHIP_IP101 PHY_CHIP_LAN8720
import .modules.tcp
import .modules.udp
import .modules.dns
import ..esp32

export MAC_CHIP_ESP32 MAC_CHIP_W5500
export PHY_CHIP_NONE PHY_CHIP_IP101 PHY_CHIP_LAN8720

ETHERNET_CONNECT_TIMEOUT_  ::= Duration --s=10
ETHERNET_DHCP_TIMEOUT_     ::= Duration --s=16

ethernet_/ethernet.Ethernet? := null
ethernet_connecting_/monitor.Latch? := null

/**
Connects the Ethernet peripheral.

The $mac_chip must be one of $MAC_CHIP_ESP32 or $MAC_CHIP_W5500.
The $phy_chip must be one of $PHY_CHIP_NONE, $PHY_CHIP_IP101 or $PHY_CHIP_LAN8720.

See https://docs.toit.io/firmware/connectivity/ethernet for documentation and
  examples.

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
      ethernet := ethernet.Ethernet
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

class EthernetInterface_ extends net.Interface:
  static open_count_/int := 0
  open_/bool := true

  constructor:
    open_count_++

  resolve host/string -> List:
    with_ethernet_:
      return [dns_lookup host]
    unreachable

  udp_open -> udp.Socket:
    return udp_open --port=null

  udp_open --port/int? -> udp.Socket:
    with_ethernet_:
      return Socket "0.0.0.0" (port ? port : 0)
    unreachable

  tcp_connect address/net.SocketAddress -> tcp.Socket:
    with_ethernet_:
      result := TcpSocket
      result.connect address.ip.stringify address.port
      return result
    unreachable

  tcp_listen port/int -> tcp.ServerSocket:
    with_ethernet_:
      result := TcpServerSocket
      result.listen "0.0.0.0" port
      return result
    unreachable

  address -> net.IpAddress:
    with_ethernet_:
      return it.address
    unreachable

  close -> none:
    if not open_: return
    open_ = false
    if --open_count_ > 0: return
    ethernet := ethernet_
    ethernet_ = null
    ethernet.close

  with_ethernet_ [block]:
    if not open_: throw "interface is closed"
    block.call ethernet_
