// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the examples/LICENSE file.

import ble.experimental.esp32
import ble.experimental.hci
import ble.experimental.transport
import ble.experimental.service.central-provider as service
import io
import .hci-trace as trace

main: run Provider

run provider/service.Provider:
  provider.install
  try:
    provider.uninstall --wait
    print "CENTRAL_PROVIDER COMPLETE"
  finally:
    provider.uninstall

class Provider extends service.Provider:
  constructor:
    super
  open-transport -> transport.Transport: return Diagnostics (esp32.Esp32Transport)

  // Separate unbonded fixture identity; preserve the public identity's bond.
  central-local-random-address info/hci.Capabilities -> ByteArray?:
    return #[0x01, 0x30, 0x23, 0xf2, 0x3a, 0xc8]

// These bounded metadata records survive scan traffic filling the header trace.
class Diagnostics extends trace.Trace:
  security-records_/int := 0
  record-limit_/int

  constructor radio/transport.Transport --record-limit/int=64:
    record-limit_ = record-limit
    super radio
    if not 1 <= record-limit <= 20_064: throw "INVALID_ARGUMENT"

  receive -> ByteArray:
    packet := super
    if security-records_ < record-limit_: record-security_ (security-event packet)
    return packet

  send packet/ByteArray -> none:
    super packet
    if security-records_ < record-limit_: record-security_ (security-command packet)

  send-if packet/ByteArray [allowed] -> bool:
    sent := super packet allowed
    if sent and security-records_ < record-limit_: record-security_ (security-command packet)
    return sent

  record-security_ metadata/string? -> none:
    if not metadata: return
    security-records_++
    print "CENTRAL_RADIO $metadata us=$(Time.monotonic-us)"

// Whitelist public fields only. Never format raw packets, LTKs or random values.
security-command packet/ByteArray -> string?:
  if packet.size != 32 or packet[..4] != #[1, 0x19, 0x20, 28]: return null
  return "enable-encryption submitted=true handle=$(io.LITTLE-ENDIAN.uint16 packet 4)"

security-event packet/ByteArray -> string?:
  if packet.size < 3 or packet[0] != 4 or packet[2] != packet.size - 3: return null
  code := packet[1]
  if packet.size == 7:
    if code == 5:
      return "disconnected status=$(packet[3]) reason=$(packet[6]) handle=$(io.LITTLE-ENDIAN.uint16 packet 4)"
    if code == 8:
      return "encryption-change status=$(packet[3]) enabled=$(packet[6]) handle=$(io.LITTLE-ENDIAN.uint16 packet 4)"
    if code == 0x0f and packet[5..] == #[0x19, 0x20]:
      return "enable-encryption command-status=$(packet[3])"
  if code == 0x3e and
      ((packet.size == 22 and packet[3] == 1) or (packet.size == 34 and packet[3] == 0x0a)):
    return "connection-complete status=$(packet[4]) handle=$(io.LITTLE-ENDIAN.uint16 packet 5) role=$(packet[7])"
  return null
