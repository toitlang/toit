// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import net
import system.api.cellular show CellularServiceClient

CONFIG_LOG_LEVEL /string ::= "cellular.log.level"

CONFIG_APN   /string ::= "cellular.apn"
CONFIG_BANDS /string ::= "cellular.bands"
CONFIG_RATS  /string ::= "cellular.rats"

CONFIG_UART_BAUD_RATE /string ::= "cellular.uart.baud"
CONFIG_UART_PRIORITY  /string ::= "cellular.uart.priority"
CONFIG_UART_RX        /string ::= "cellular.uart.rx"
CONFIG_UART_TX        /string ::= "cellular.uart.tx"
CONFIG_UART_CTS       /string ::= "cellular.uart.cts"
CONFIG_UART_RTS       /string ::= "cellular.uart.rts"

CONFIG_POWER /string ::= "cellular.power"
CONFIG_RESET /string ::= "cellular.reset"

CONFIG_ACTIVE_LOW  /int ::= 0
CONFIG_ACTIVE_HIGH /int ::= 1
CONFIG_OPEN_DRAIN  /int ::= 2

CONFIG_PRIORITY_LOW  /int ::= 0
CONFIG_PRIORITY_HIGH /int ::= 1

service_/CellularServiceClient? := null
service_initialized_/bool := false

open config/Map? -> net.Client:
  if not service_initialized_:
    // We typically run the cellular service in a non-system
    // container with --trigger=boot, so we need to give it
    // time to start so it can be discovered. We should really
    // generalize this handling for net.open and wifi.open too,
    // so we get a shared pattern for dealing with discovering
    // such network services at start up.
    service_initialized_ = true
    service_ = (CellularServiceClient).open
        --timeout=(Duration --s=5)
        --if_absent=: null
  service := service_
  if not service: throw "cellular unavailable"
  return net.Client service (service.connect config)
