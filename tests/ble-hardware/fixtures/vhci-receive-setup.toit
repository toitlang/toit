// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.esp32
import ble.experimental.hci
import encoding.hex
import io
import system

// No connections are established. Command acceptance is not a credit-window test.
main:
  20.repeat: | cycle/int |
    controller := hci.Controller (esp32.Esp32Transport)
    try:
      info := hci.initialize controller
      if info.commands[10] & 0xe0 != 0xe0: throw "RX_FLOW_COMMANDS_UNSUPPORTED"
      // These controller builds reject 27-byte host buffers with status 0x11.
      length := 1024
      // Core Vol 4 Part E 7.3.39: ACL length, SCO length, ACL count, SCO count.
      parameters := #[0, 0, 0, 4, 0, 0, 0]
      io.LITTLE-ENDIAN.put-uint16 parameters 0 length
      configure controller cycle 0x0c33 parameters
      configure controller cycle 0x0c31 #[1]
      configure controller cycle 0x0c31 #[0]
      if (controller.command hci.READ-ADDRESS) != info.address:
        throw "RX_FLOW_ADDRESS_CHANGED"
      print "RX_FLOW_SETUP cycle=$cycle length=$length count=4 address=$(hex.encode info.address.reverse)"
    finally:
      controller.close
      controller.wait-closed
    system.process-stats --gc
  print "RX_FLOW_SETUP COMPLETE cycles=20"

configure controller/hci.Controller cycle/int opcode/int parameters/ByteArray -> none:
  result := controller.command opcode parameters
  if not result.is-empty: throw "RX_FLOW_UNEXPECTED_RESPONSE"
  // Controller.command only returns after a status-zero Command Complete.
  print "RX_FLOW_COMMAND cycle=$cycle opcode=$opcode parameters=$(hex.encode parameters) status=0"
