// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import bytes
import log
import uart
import at

import .ublox_cellular
import .cellular_base
import .cellular

/**
Driver for Sara-R5, GSM communicating over NB-IoT & M1.
*/
class SaraR5 extends UBloxCellular:
  static CONFIG_ ::= {:}

  pwr_on/Pin?
  reset_n/Pin?

  constructor uart/uart.Port --logger=log.default --.pwr_on=null --.reset_n=null --is_always_online/bool:
    super
      uart
      --logger=logger
      --config=CONFIG_
      --cat_m1
      --preferred_baud_rate=3250000
      --use_psm=not is_always_online

  on_connected_ session/at.Session:
    // Attach to network.
    session.set "+UPSD" [0, 100, 1]
    session.set "+UPSD" [0, 0, 0]
    session.set "+UPSDA" [0, 0]
    session.set "+UPSDA" [0, 3]

  on_reset session/at.Session:
    session.send
      CFUN.reset --reset_sim

  power_on -> none:
    if pwr_on:
      pwr_on.on
      sleep --ms=1000
      pwr_on.off

  power_off -> none:
    if pwr_on and reset_n:
      pwr_on.on
      reset_n.on
      sleep --ms=23_000
      pwr_on.off
      sleep --ms=1500
      reset_n.off

  reset -> none:
    if reset_n:
      reset_n.on
      sleep --ms=100
      reset_n.off

  // Prefer reset over power_off (100ms vs ~25s).
  recover_modem:
    reset
