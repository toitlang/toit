// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import gpio
import system

import .variants

BOARD1-IN ::= Variant.CURRENT.board-connection-pin1
BOARD1-OUT ::= Variant.CURRENT.board-connection-pin2
BOARD2-IN ::= Variant.CURRENT.board-connection-pin2
BOARD2-OUT ::= Variant.CURRENT.board-connection-pin1

RIG-PEER-TIMEOUT-MS ::= 5_000
RIG-PEER-LINK-FAILED ::= "RIG_PEER_LINK_FAILED"

wait-for-rig-level pin/gpio.Pin pin-number/int level/int board/string phase/string:
  error := catch:
    with-timeout --ms=RIG-PEER-TIMEOUT-MS:
      while pin.get != level: sleep --ms=1
  if error == DEADLINE-EXCEEDED-ERROR:
    print "Rig health failed on $board during $phase: pin $pin-number did not reach level $level in $(RIG-PEER-TIMEOUT-MS)ms"
    throw RIG-PEER-LINK-FAILED
  if error: throw error
