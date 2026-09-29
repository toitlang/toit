// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.native as native
import encoding.hex

// Only the isolated --fault-injection firmware enables the test primitive.
// Direct primitives keep automatic readers from consuming injected packets.
main args/List:
  if args.size > 1 or (args.size == 1 and args[0] != "disabled"):
    throw "Usage: vhci-faults.toit [disabled]"
  group := init_
  if not args.is-empty:
    with-radio group: | radio |
      error := catch: test_ radio 2 #[4, 14, 1, 7]
      if error != "UNIMPLEMENTED": throw "FAULT_HOOK_ENABLED"
    print "VHCI_FAULTS DISABLED"
    return
  ["HCI_QUEUE_OVERFLOW", "HCI_INVALID_PACKET", "HCI_OVERSIZED_PACKET"].do: | fault/string |
    with-radio group: | radio |
      if fault == "HCI_QUEUE_OVERFLOW":
        8.repeat:
          if (test_ radio 2 #[4, 14, 1, 7]) != 0: throw "EARLY_QUEUE_OVERFLOW"
        if (test_ radio 2 #[2, 1, 0, 1, 0, 9]) != 2: throw "MISSING_QUEUE_OVERFLOW"
      else if fault == "HCI_INVALID_PACKET":
        if (test_ radio 2 #[4, 14, 4]) != 2: throw "MISSING_INVALID_PACKET"
      else:
        if (test_ radio 2 (ByteArray 1030)) != 2: throw "MISSING_OVERSIZED_PACKET"
      diagnostics := native.QueueDiagnostics (diagnostics_ radio)
      if diagnostics.fault != fault: throw "QUEUE_FAULT_MISMATCH"
      if fault == "HCI_QUEUE_OVERFLOW" and (diagnostics.queued != 8 or diagnostics.high-water != 8):
        throw "OVERFLOW_QUEUE_COUNT"
      error := catch: receive_ radio 1029
      if error != "ERROR": throw "FAULT_RECEIVE_SUCCEEDED"
      error = catch: send_ radio #[1, 3, 12, 0]
      if error != "ERROR": throw "FAULT_SEND_SUCCEEDED"
      if (test_ radio 2 #[4, 14, 1, 7]) != 2: throw "FAULT_WAS_NOT_TERMINAL"
      print "VHCI_FAULTS fault=$fault terminal=true"
  with-radio group: | radio |
    diagnostics := native.QueueDiagnostics (diagnostics_ radio)
    if diagnostics.queued != 0 or diagnostics.fault: throw "REOPEN_AFTER_FAULT_FAILED"
    with-timeout --ms=3_000:
      while not (send_ radio #[1, 3, 12, 0]): sleep --ms=1
      packet/ByteArray? := null
      while not packet:
        packet = receive_ radio 1029
        if not packet: sleep --ms=1
      print "VHCI_FAULTS reset=$(hex.encode packet)"
      if packet.size != 7 or packet[0..3] != #[4, 14, 4] or packet[3] == 0 or packet[4..] != #[3, 12, 0]:
        throw "REOPEN_RESET_FAILED"
  print "VHCI_FAULTS COMPLETE retries=20 faults=3 reopened=true"

with-radio group [body] -> none:
  radio := open_ group 0
  try:
    body.call radio
  finally:
    close_ group radio

init_:
  #primitive.ble_hci.init
open_ group adapter/int:
  #primitive.ble_hci.open
receive_ resource limit/int -> ByteArray?:
  #primitive.ble_hci.receive
send_ resource packet/ByteArray -> bool:
  #primitive.ble_hci.send
close_ group resource -> none:
  #primitive.ble_hci.close
diagnostics_ resource -> ByteArray:
  #primitive.ble_hci.diagnostics
test_ resource action/int packet/ByteArray:
  #primitive.ble_hci.test
