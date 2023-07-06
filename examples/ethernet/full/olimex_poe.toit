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

The pins are configured for the Olimex ESP32-POE board, which
  needs an envelope with an RMII clock output: `firmware-esp32-eth-clk-out17`.

This firmware contains the following sdk-config change (enable
  `CONFIG_ETH_RMII_CLK_OUTPUT`):

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

  on_module_opened module:
    super module
    power_ = gpio.Pin --output 12
    power_.set 1

  on_module_closed module:
    super module
    if power_:
      critical_do:
        power_.close
        power_ = null
