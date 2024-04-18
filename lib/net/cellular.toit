// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import net
import system.api.cellular show CellularServiceClient

CONFIG-LOG-LEVEL /string ::= "cellular.log.level"

CONFIG-APN   /string ::= "cellular.apn"
CONFIG-BANDS /string ::= "cellular.bands"
CONFIG-RATS  /string ::= "cellular.rats"

CONFIG-UART-BAUD-RATE /string ::= "cellular.uart.baud"
CONFIG-UART-PRIORITY  /string ::= "cellular.uart.priority"
CONFIG-UART-RX        /string ::= "cellular.uart.rx"
CONFIG-UART-TX        /string ::= "cellular.uart.tx"
CONFIG-UART-CTS       /string ::= "cellular.uart.cts"
CONFIG-UART-RTS       /string ::= "cellular.uart.rts"

CONFIG-POWER /string ::= "cellular.power"
CONFIG-RESET /string ::= "cellular.reset"

CONFIG-ACTIVE-LOW  /int ::= 0
CONFIG-ACTIVE-HIGH /int ::= 1
CONFIG-OPEN-DRAIN  /int ::= 2

CONFIG-PRIORITY-LOW  /int ::= 0
CONFIG-PRIORITY-HIGH /int ::= 1

service_/CellularServiceClient? := null
service-initialized_/bool := false

open config/Map? -> net.Client
    --name/string?=null:
  if not service-initialized_:
    // We typically run the cellular service in a non-system
    // container with --trigger=boot, so we need to give it
    // time to start so it can be discovered. We should really
    // generalize this handling for net.open and wifi.open too,
    // so we get a shared pattern for dealing with discovering
    // such network services at start up.
    service_ = (CellularServiceClient).open
        --timeout=(Duration --s=5)
        --if-absent=: null
    // If opening the client failed due to exceptions or
    // cancelation, we will try again next time $open is
    // called. If the service was just absent even after
    // having waited for it to appear, we will not try
    // again unless $reset has been called in between.
    service-initialized_ = true
  service := service_
  if not service: throw "cellular unavailable"
  return net.Client service --name=name (service.connect config)

/**
Resets the cellular client.

This allows re-establishing the link to the cellular service
  provider at a later time. At that point, the service provider
  may have changed, so calling $reset enables reacting to that.
*/
reset -> none:
  service := service_
  service_ = null
  service-initialized_ = false
  if service: service.close
