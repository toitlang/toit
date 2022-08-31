// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import net
import system.api.cellular show CellularServiceClient

import .impl

CONFIG_LOG_LEVEL / string ::= "log.level"

CONFIG_APN   /string ::= "apn"
CONFIG_BANDS /string ::= "bands"
CONFIG_RATS  /string ::= "rats"

CONFIG_UART_BAUD_RATE /string ::= "uart.baud"
CONFIG_UART_RX        /string ::= "uart.rx"
CONFIG_UART_TX        /string ::= "uart.tx"
CONFIG_UART_CTS       /string ::= "uart.cts"
CONFIG_UART_RTS       /string ::= "uart.rts"

CONFIG_POWER /string ::= "power"
CONFIG_RESET /string ::= "reset"

CONFIG_ACTIVE_LOW  /int ::= 0
CONFIG_ACTIVE_HIGH /int ::= 1
CONFIG_OPEN_DRAIN  /int ::= 2

service_/CellularServiceClient? ::= (CellularServiceClient --no-open).open

open config/Map? -> net.Interface:
  service := service_
  if not service: throw "cellular unavailable"
  return SystemInterface_ service (service.connect config)
