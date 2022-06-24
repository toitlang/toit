// Copyright (C) 2022 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import system.api.network show NetworkService NetworkServiceClient
import gpio

// TODO: configurable psm <-> not-psm
// TODO: configurable logging level

// timeouts:

interface CellularService extends NetworkService:
  static UUID  /string ::= "83798564-d965-49bf-b69d-7f05a082f4f0"
  static MAJOR /int    ::= 0
  static MINOR /int    ::= 1

  static CONNECT_INDEX /int ::= 1000
  connect wiring/CellularWiring apn/string bands/List? rats/List? -> List

class CellularServiceClient extends NetworkServiceClient implements CellularService:
  constructor --open/bool=true:
    super --open=open

  open -> CellularServiceClient?:
    return (open_ CellularService.UUID CellularService.MAJOR CellularService.MINOR) and this

  connect wiring/CellularWiring apn/string bands/List? rats/List? -> List:
    return invoke_ CellularService.CONNECT_INDEX [wiring.serialize, apn, bands, rats]

class CellularWiring:
  static DEFAULT_BAUD_RATE /int ::= 115_200

  static MODE_ACTIVE_LOW  /int ::= 0
  static MODE_ACTIVE_HIGH /int ::= 1
  static MODE_OPEN_DRAIN  /int ::= 2

  baud_rate_ / int := DEFAULT_BAUD_RATE
  tx_ / int := 0
  rx_ / int := 0
  cts_ / int? := null
  rts_ / int? := null
  power_ / int := 0
  reset_ / int := 0

  constructor:
    // Do nothing.

  constructor.deserialize serialized/List:
    baud_rate_ = serialized[0]
    tx_ = serialized[1]
    rx_ = serialized[2]
    cts_ = serialized[3]
    rts_ = serialized[4]
    power_ = serialized[5]
    reset_ = serialized[6]

  serialize -> List:
    return [ baud_rate_, tx_, rx_, cts_, rts_, power_, reset_ ]

  baud_rate -> int:
    return baud_rate_

  tx -> gpio.Pin:
    return gpio.Pin tx_

  rx -> gpio.Pin:
    return gpio.Pin rx_

  cts -> gpio.Pin?:
    return cts_ ? (gpio.Pin cts_) : null

  rts -> gpio.Pin?:
    return rts_ ? (gpio.Pin rts_) : null

  power -> gpio.Pin:
    return pin_ power_

  reset -> gpio.Pin:
    return pin_ reset_

  configure_baud_rate rate/int -> none:
    baud_rate_ = rate

  configure_tx --pin/int -> none:
    tx_ = pin

  configure_rx --pin/int -> none:
    rx_ = pin

  configure_cts --pin/int -> none:
    cts_ = pin

  configure_rts --pin/int -> none:
    rts_ = pin

  configure_power --pin/int --mode/int -> none:
    power_ = (pin << 2) | mode

  configure_reset --pin/int --mode/int -> none:
    reset_ = (pin << 2) | mode

  static pin_ encoded/int -> gpio.Pin:
    pin := gpio.Pin (encoded >> 2)
    mode ::= encoded & 0b11
    // TODO(kasper): Verify that this is correct for MODE_OPEN_DRAIN.
    if mode != MODE_ACTIVE_HIGH: pin = gpio.InvertedPin pin
    pin.config --output --open_drain=(mode == MODE_OPEN_DRAIN)
    pin.set 0  // Drive to in-active.
    return pin
