// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.hci
import ble.experimental.linux
import ble.experimental.transport
import encoding.hex
import io
import system

main args/List:
  if args.size != 1: throw "Usage: bounded-advertising.toit <adapter index>"
  run (linux.LinuxTransport (int.parse args.first))

// Tests a prerequisite for isolated accept cancellation, not service admission.
// No connection is expected; a connection event deliberately fails the probe.
run radio/transport.Transport:
  controller := hci.Controller radio
  try:
    info := hci.initialize controller
    print "BOUNDED_ADV address=$(hex.encode info.address.reverse) le-features=$(hex.encode info.le-features)"
    if info.le-features[1] & 0x10 == 0: throw "EXTENDED_ADVERTISING_UNSUPPORTED"
    // Connection Complete, Enhanced Connection Complete and Set Terminated.
    controller.command hci.LE-SET-EVENT-MASK #[0x1f, 2, 2, 0, 0, 0, 0, 0]
    // Legacy connectable/scannable PDUs through extended HCI commands. Do not
    // mix legacy advertising, scanning or initiating commands in this lifetime.
    selected := controller.command 0x2036 #[
      0, 0x13, 0, 160, 0, 0, 160, 0, 0, 7, 0, 0,
      0, 0, 0, 0, 0, 0, 0, 0x7f, 1, 0, 1, 0, 0,
    ]
    if selected.size != 1: throw "INVALID_SELECTED_TX_POWER"
    controller.command 0x2037 #[0, 3, 1, 3, 2, 1, 6]
    count-deviations := 0
    timeout-completions := 0
    9.repeat: | cycle/int |
      duration/int := [10, 100, 1000][cycle / 3]
      start := Time.monotonic-us
      // Duration is in 10-ms units. Wait for natural expiry rather than
      // issuing Disable, which has no mandatory Set Terminated response.
      parameters := #[1, 1, 0, 0, 0, 0]
      io.LITTLE-ENDIAN.put-uint16 parameters 3 duration
      controller.command 0x2039 parameters
      packet := with-timeout --ms=(duration * 10 + 3_000):
        event := controller.receive
        // Some controllers also emit a failed Connection Complete for expiry
        // of undirected advertising. Record it, but still require termination.
        if event.size >= 5 and event[..2] == #[4, 0x3e] and event[4] == 0x3c and
            ((event.size == 22 and event[3] == 1) or (event.size == 34 and event[3] == 0x0a)):
          timeout-completions++
          print "BOUNDED_ADV timeout-completion=$(hex.encode event)"
          event = controller.receive
        event
      if packet.size != 9 or packet[..6] != #[4, 0x3e, 6, 0x12, 0x3c, 0]:
        throw "UNEXPECTED_ADVERTISING_EVENT: $(hex.encode packet)"
      // Core 6.3 7.7.65.18 requires zero with no maximum event count. Some
      // controllers report a count anyway; retain this separate discrepancy.
      if packet[8] != 0: count-deviations++
      print "BOUNDED_ADV cycle=$cycle duration-units=$duration elapsed-us=$(Time.monotonic-us - start) event=$(hex.encode packet)"
      system.process-stats --gc
    controller.command 0x203c #[0]
    print "BOUNDED_ADV COMPLETE cycles=9 count-deviations=$count-deviations timeout-completions=$timeout-completions"
  finally:
    controller.close
    controller.wait-closed
