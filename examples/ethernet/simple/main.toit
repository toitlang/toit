// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

/**
Example of using the ESP32 Ethernet driver.

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
import net
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
  use network
  network.close
  provider.uninstall
  power.close

use network/net.Client:
  // Use the network.
