// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.esp32
import ble.experimental.hci
import io
import .vhci-receive-setup as setup

// Isolates buffer length and setup order after a rejected setup inquiry.
main:
  accepted := 0
  4.repeat: | round/int |
    length := round % 2 == 0 ? 27 : 1024
    enable-first := round >= 2
    controller := hci.Controller (esp32.Esp32Transport)
    try:
      info := hci.initialize controller
      if info.commands[10] & 0xe0 != 0xe0: throw "RX_FLOW_COMMANDS_UNSUPPORTED"
      parameters := #[0, 0, 0, 4, 0, 0, 0]
      io.LITTLE-ENDIAN.put-uint16 parameters 0 length
      print "RX_FLOW_PROBE round=$round length=$length enable-first=$enable-first"
      enabled := false
      buffered := false
      if enable-first:
        enabled = probe controller round 0x0c31 #[1]
        buffered = probe controller round 0x0c33 parameters
      else:
        buffered = probe controller round 0x0c33 parameters
        enabled = probe controller round 0x0c31 #[1]
      // Always require successful disabling and subsequent ordinary commands.
      setup.configure controller round 0x0c31 #[0]
      if (controller.command hci.READ-ADDRESS) != info.address:
        throw "RX_FLOW_ADDRESS_CHANGED"
      if enabled and buffered: accepted++
      print "RX_FLOW_PROBE_RESULT round=$round enabled=$enabled buffered=$buffered disabled=true"
    finally:
      controller.close
      controller.wait-closed
  print "RX_FLOW_PROBE COMPLETE rounds=4 accepted=$accepted"

probe controller/hci.Controller round/int opcode/int parameters/ByteArray -> bool:
  error := catch: setup.configure controller round opcode parameters
  if not error: return true
  if not error is hci.CommandError: throw error
  print "RX_FLOW_REJECTED round=$round opcode=$opcode status=$error.status"
  return false
