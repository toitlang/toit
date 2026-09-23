// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can
// be found in the lib/LICENSE file.

import io
import .advertising as advertising
import .hci as hci
import .scanning show Statistics

/** Legacy advertisement discovery compatible with extended initiating commands. */

/**
Scans legacy advertisements using extended commands, passive LE 1M and public addressing.

Requires a freshly initialized controller, before assigning a protocol host.
  Configures the ordinary initialization LE event mask plus Extended Advertising
  Report. Legacy scan/initiating commands must not be used in this lifetime.
  This discovery operation remains exclusive; it does not arbitrate active links.

Calls the scoped $report block until it returns false. Only complete legacy PDUs
  are delivered as advertising.Report objects. Extended PDUs are ignored; their
  data is neither reassembled nor exposed as a complete legacy advertisement.
  Retained reports own managed packet storage. Slow consumers drop new report
  events at the bounded queue. Returns the number of dropped events.

All exits disable scanning; failed disable closes the controller. Use an outer
  with-timeout for a finite discovery deadline. See Core 6.3 Vol 4 Part E,
  sections 7.8.64, 7.8.65 and 7.7.65.13.
*/
scan controller/hci.Controller info/hci.Capabilities
    --queue-limit/int=32 --statistics/Statistics?=null [report] -> int:
  if info.le-features[1] & 0x10 == 0 or info.commands[37] & 0x60 != 0x60:
    throw "HCI_EXTENDED_SCANNING_UNSUPPORTED"
  reports := controller.open-reports --limit=queue-limit
  enabled := false
  if statistics:
    statistics.stopped = false
    statistics.dropped-events = 0
  try:
    controller.command hci.LE-SET-EVENT-MASK #[0x5f, 0x1a, 0, 0, 0, 0, 0, 0]
    controller.command 0x2041 #[0, 0, 1, 0, 0x10, 0, 0x10, 0]
    controller.command 0x2042 #[1, 1, 0, 0, 0, 0]
    enabled = true
    running := true
    while running:
      packet := reports.take
      reports-do packet: | decoded/advertising.Report |
        if running: running = report.call decoded
    return reports.dropped
  finally:
    try:
      if enabled:
        stopped := false
        try:
          critical-do --no-respect-deadline:
            controller.command 0x2042 #[0, 0, 0, 0, 0, 0]
          stopped = true
          if statistics: statistics.stopped = true
        finally:
          if not stopped: controller.close
    finally:
      if statistics: statistics.dropped-events = reports.dropped
      controller.close-reports reports

/**
Delivers legacy PDUs from an Extended Advertising Report event through a block.

Validates the entire event before any delivery. Returns false for unrelated
  events. Unsupported extended PDUs are length-checked but never delivered.
  Invalid legacy event flags, PHY fields or payload sizes fail explicitly.
  Unavailable/reserved RSSI becomes null; address types remain explicit.
*/
reports-do packet/ByteArray [report] -> bool:
  hci.validate-packet packet
  if packet[0] != 4 or packet[1] != 0x3e: return false
  if packet.size < 4: throw "HCI_MALFORMED_ADVERTISING_REPORT"
  if packet[3] != 0x0d: return false
  if packet.size < 5 or not 1 <= packet[4] <= 10: throw "HCI_MALFORMED_ADVERTISING_REPORT"
  offset := 5
  packet[4].repeat:
    if offset + 24 > packet.size: throw "HCI_MALFORMED_ADVERTISING_REPORT"
    length := packet[offset + 23]
    if offset + 24 + length > packet.size: throw "HCI_MALFORMED_ADVERTISING_REPORT"
    flags := io.LITTLE-ENDIAN.uint16 packet offset
    if flags & 0x10 != 0:
      if (legacy-type_ flags) < 0 or length > 31 or packet[offset + 9] != 1 or packet[offset + 10] != 0:
        throw "HCI_MALFORMED_ADVERTISING_REPORT"
    offset += 24 + length
  if offset != packet.size: throw "HCI_MALFORMED_ADVERTISING_REPORT"
  offset = 5
  packet[4].repeat:
    length := packet[offset + 23]
    type := legacy-type_ (io.LITTLE-ENDIAN.uint16 packet offset)
    if type >= 0:
      raw := packet[offset + 13]
      signed := raw < 128 ? raw : raw - 256
      decoded := advertising.Report type packet[offset + 2]
          packet[offset + 3..offset + 9]
          packet[offset + 24..offset + 24 + length]
          (-127 <= signed <= 20 ? signed : null)
      report.call decoded
    offset += 24 + length
  return true

legacy-type_ flags/int -> int:
  if flags == 0x13: return 0
  if flags == 0x15: return 1
  if flags == 0x12: return 2
  if flags == 0x10: return 3
  if flags == 0x1b or flags == 0x1a: return 4
  return -1
