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

MAC-CHIP-ESP32    ::= 0
MAC-CHIP-W5500    ::= 1
MAC-CHIP-OPENETH  ::= 2

PHY-CHIP-NONE     ::= 0
PHY-CHIP-IP101    ::= 1
PHY-CHIP-LAN8720  ::= 2
PHY-CHIP-DP83848  ::= 3

// The private base class is used only for sharing parts of the
// construction code, so the constructors in the subclass are
// kept small without turning them into factory constructors.
abstract class EthernetServiceProviderBase_ extends ServiceProvider
    implements ServiceHandler:
  create-resource-group_/Lambda
  constructor .create-resource-group_:
    super "system/ethernet/esp32" --major=0 --minor=2
        --tags=[NetworkService.TAG-ETHERNET]
    provides NetworkService.SELECTOR
        --handler=this
        --priority=ServiceProvider.PRIORITY-PREFERRED
    provides EthernetService.SELECTOR
        --handler=this
  abstract handle index/int arguments/any --gid/int --client/int -> any

/**
Service provider for networking via the Ethernet peripheral.

This provider must be installed before Ethernet networking can be used
  on the ESP32. The provider can be installed in a separate container
  or in the same container as the application.

# Example

An example of how to install the service provider in the same
  container. This example is for the Olimex ESP32-POE board.

```
import gpio
import net.ethernet
import esp32.net.ethernet as esp32

main:
  power := gpio.Pin --output 12
  power.set 1
  provider := esp32.EthernetServiceProvider.mac-esp32
      --phy-chip=esp32.PHY-CHIP-LAN8720
      --phy-address=0
      --mac-mdc=gpio.Pin 23
      --mac-mdio=gpio.Pin 18
  provider.install
  network := ethernet.open
  try:
    use network
  finally:
    network.close
    provider.uninstall
    power.close
```

# Olimex Ethernet boards
The Olimex Ethernet boards (Gateway and ESP32-POE)
  need an envelope with an RMII clock output: `esp32-eth-clk-out17`
  (WROOM) or `esp32-eth-clk-out0-spiram` (WROVER).

This firmware contains the sdk-config change to  enable
  `CONFIG_ETH_RMII_CLK_OUTPUT` (here for the WROOM):

```
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

# Lilygo T-Internet-COM
The [Lilygo T-Internet-COM](https://lilygo.cc/products/t-internet-com) is similar
  to the Olimex board. It uses the `esp32-eth-clk-out0-spiram` envelope
  and GPIO 4 as power pin. The rest is the same.
*/
class EthernetServiceProvider extends EthernetServiceProviderBase_:
  state_/NetworkState ::= NetworkState

  /**
  The $mac-chip must be one of $MAC-CHIP-ESP32 or $MAC-CHIP-OPENETH.
  The $phy-chip must be one of $PHY-CHIP-IP101, $PHY-CHIP-LAN8720, or $PHY-CHIP-DP83848.

  Deprecated. Use $EthernetServiceProvider.mac-esp32,
    $EthernetServiceProvider.mac-openeth, or $EthernetServiceProvider.w5500 instead.
  */
  constructor
      --phy-chip/int
      --phy-address/int=-1
      --phy-reset/gpio.Pin?=null
      --mac-chip/int
      --mac-mdc/gpio.Pin?
      --mac-mdio/gpio.Pin?
      --mac-spi-device/spi.Device?
      --mac-interrupt/gpio.Pin?:
    if mac-chip != MAC-CHIP-ESP32 and mac-chip != MAC-CHIP-OPENETH:
      throw "unsupported mac type: $mac-chip"
    super::
      ethernet-init_
          mac-chip
          phy-chip
          phy-address
          phy-reset ? phy-reset.num : -1
          mac-mdc ? mac-mdc.num : -1
          mac-mdio ? mac-mdio.num : -1

  /**
  The $phy-chip must be one of $PHY-CHIP-IP101, $PHY-CHIP-LAN8720, or $PHY-CHIP-DP83848.
  */
  constructor.mac-esp32
      --phy-chip/int
      --phy-address/int=-1
      --phy-reset/gpio.Pin?=null
      --mac-mdc/gpio.Pin?=null
      --mac-mdio/gpio.Pin?=null:
    super::
      ethernet-init_
          MAC-CHIP-ESP32
          phy-chip
          phy-address
          phy-reset ? phy-reset.num : -1
          mac-mdc ? mac-mdc.num : -1
          mac-mdio ? mac-mdio.num : -1

  /**
  The $phy-chip must be one of $PHY-CHIP-IP101, $PHY-CHIP-LAN8720, or $PHY-CHIP-DP83848.
  */
  constructor.mac-openeth
      --phy-chip/int
      --phy-address/int=-1
      --phy-reset/gpio.Pin?=null:
    super::
      ethernet-init_
          MAC-CHIP-OPENETH
          phy-chip
          phy-address
          phy-reset ? phy-reset.num : -1
          -1
          -1

  constructor.w5500
      --bus/spi.Bus
      --frequency/int
      --cs/gpio.Pin
      --interrupt/gpio.Pin:
    super::
      ethernet-init-spi_
          MAC-CHIP-W5500
          bus.spi_
          frequency
          cs.num
          interrupt.num

  handle index/int arguments/any --gid/int --client/int -> any:
    if index == NetworkService.CONNECT-INDEX:
      return connect client
    if index == NetworkService.ADDRESS-INDEX:
      network := (resource client arguments) as NetworkResource
      return address network
    unreachable

  connect client/int -> List:
    state_.up: EthernetModule_ this create-resource-group_
    try:
      resource := NetworkResource this client state_ --notifiable
      return [
        resource.serialize-for-rpc,
        NetworkService.PROXY-ADDRESS,
        "ethernet"
      ]
    finally: | is-exception exception |
      // If we're not returning a network resource to the client, we
      // must take care to decrement the usage count correctly.
      if is-exception: state_.down

  address resource/NetworkResource -> ByteArray:
    return (state_.module as EthernetModule_).address.to-byte-array

  /**
  Called when the module is first opened, for example through `ethernet.open`.

  # Inheritance
  This method must be called by any subclass that overrides it.
  */
  on-module-opened module/EthernetModule_ -> none:

  /**
  Called when the module is closed, for example through `network.close`.

  # Inheritance
  This method must be called by any subclass that overrides it.
  */
  on-module-closed module/EthernetModule_ -> none:
    critical-do:
      resources-do: | resource/NetworkResource |
        if not resource.is-closed:
          resource.notify_ NetworkService.NOTIFY-CLOSED --close

class EthernetModule_ implements NetworkModule:
  static ETHERNET-CONNECT-TIMEOUT ::= Duration --s=10
  static ETHERNET-DHCP-TIMEOUT    ::= Duration --s=16

  static ETHERNET-CONNECTED    ::= 1 << 0
  static ETHERNET-DHCP-SUCCESS ::= 1 << 1
  static ETHERNET-DISCONNECTED ::= 1 << 2

  logger_/log.Logger ::= log.default.with-name "ethernet"
  service/EthernetServiceProvider

  resource-group_ := ?
  address_/net.IpAddress? := null

  constructor .service create-resource-group/Lambda:
    resource-group_ = create-resource-group.call

  address -> net.IpAddress:
    return address_

  connect -> none:
    service.on-module-opened this
    with-timeout ETHERNET-CONNECT-TIMEOUT: wait-for-connected_
    with-timeout ETHERNET-DHCP-TIMEOUT: wait-for-dhcp-ip-address_

  disconnect -> none:
    if not resource-group_: return
    logger_.debug "closing"
    ethernet-close_ resource-group_
    resource-group_ = null
    address_ = null
    service.on-module-closed this

  wait-for-connected_ -> none:
    logger_.debug "connecting"
    while true:
      resource := ethernet-connect_ resource-group_
      ethernet-events := monitor.ResourceState_ resource-group_ resource
      state := ethernet-events.wait
      ethernet-events.dispose
      if (state & ETHERNET-CONNECTED) != 0:
        logger_.debug "connected"
        return
      else if (state & ETHERNET-DISCONNECTED) != 0:
        logger_.warn "connect failed"
        throw "CONNECT_FAILED"

  wait-for-dhcp-ip-address_ -> none:
    resource := ethernet-setup-ip_ resource-group_
    ip-events := monitor.ResourceState_ resource-group_ resource
    state := ip-events.wait
    ip-events.dispose
    if (state & ETHERNET-DHCP-SUCCESS) == 0: throw "IP_ASSIGN_FAILED"
    ip := ethernet-get-ip_ resource
    address_ = net.IpAddress ip
    logger_.info "network address dynamically assigned through dhcp" --tags={"ip": address_}

ethernet-init_ mac-chip/int phy-chip/int phy-addr/int phy-reset-num/int mac-mdc-num/int mac-mdio-num/int:
  #primitive.ethernet.init

ethernet-init-spi_ mac-chip/int spi frequency/int cs-num/int int-num/int:
  #primitive.ethernet.init-spi

ethernet-close_ resource-group:
  #primitive.ethernet.close

ethernet-connect_ resource-group:
  #primitive.ethernet.connect

ethernet-setup-ip_ resource-group:
  #primitive.ethernet.setup-ip

ethernet-disconnect_ resource-group resource:
  #primitive.ethernet.disconnect

ethernet-get-ip_ resource:
  #primitive.ethernet.get-ip
