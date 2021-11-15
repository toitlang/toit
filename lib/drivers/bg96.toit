// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import bytes
import log
import uart
import at

import .quectel_cellular
import .cellular

/**
Driver for BG96, LTE-M modem.
*/
class BG96 extends QuectelCellular:
  pwrkey/Pin?
  rstkey/Pin?

  constructor uart/uart.Port --logger=log.default --.pwrkey=null --.rstkey=null --is_always_online/bool:
    super
      uart
      --logger=logger
      --preferred_baud_rate=921600
      --use_psm=not is_always_online

  on_connected_ session/at.Session:
    // Attach to network.
    session.set "+QICSGP" [cid_]
    session.set "+QIACT" [cid_]

  on_reset session/at.Session:
    session.set "+CFUN" [1, 1]

  power_on -> none:
    if pwrkey:
      pwrkey.on
      sleep --ms=150
      pwrkey.off

  power_off -> none:
    if pwrkey:
      pwrkey.on
      sleep --ms=650
      pwrkey.off

  reset -> none:
    if rstkey:
      rstkey.on
      sleep --ms=150
      rstkey.off

  recover_modem -> none:
    if rstkey:
      reset
    else:
      power_off
