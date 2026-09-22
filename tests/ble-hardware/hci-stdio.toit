// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.linux
import io
import monitor

// Optional radio-test transport for an independent host. The outer supervisor
// must verify adapter identity, reserve ownership and restore power afterward.
// Standard streams carry binary H4 packets; never redirect them to a trace file.
// This relay performs framing only, with no Toit HCI command or BLE host engine.
main arguments/List:
  seconds := timeout-seconds arguments
  adapter := int.parse arguments[0]
  if not 0 <= adapter < 0xffff: throw "INVALID_ARGUMENT"
  radio := linux.LinuxTransport adapter
  ended := monitor.Latch
  incoming/Task? := null
  outgoing/Task? := null
  try:
    incoming = task::
      error := catch:
        while packet := read-packet io.stdin:
          radio.send packet
      if not ended.has-value: ended.set error
    outgoing = task::
      error := catch:
        while true: io.stdout.write radio.receive
      if not ended.has-value: ended.set error
    error := with-timeout --ms=(seconds * 1_000): ended.get
    if error: throw error
  finally:
    radio.close
    if incoming: incoming.cancel
    if outgoing: outgoing.cancel

// Longer optional campaigns must still have a bounded transport lifetime.
timeout-seconds arguments/List -> int:
  if not 1 <= arguments.size <= 2: throw "Usage: hci-stdio ADAPTER [SECONDS]"
  seconds := arguments.size == 2 ? (int.parse arguments[1]) : 120
  if not 1 <= seconds <= 7_200: throw "INVALID_ARGUMENT"
  return seconds

// Reject an unsupported type or excessive length before reading its payload.
// EOF is normal only between complete packets; a partial header/body fails.
read-packet input/io.Reader -> ByteArray?:
  if not (input.try-ensure-buffered 1): return null
  kind := input.read-byte
  if kind != 1 and kind != 2: throw "HCI_BRIDGE_PACKET_TYPE"
  header := input.read-bytes (kind == 1 ? 3 : 4)
  length := kind == 1 ? header[2] : (io.LITTLE-ENDIAN.uint16 header 2)
  if 1 + header.size + length > 2048: throw "HCI_BRIDGE_PACKET_TOO_LARGE"
  return #[kind] + header + (input.read-bytes length)
