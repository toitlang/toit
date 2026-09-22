// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble.experimental.linux-management
import ble.experimental.native
import encoding.hex
import io

// Passive management-channel diagnostics alongside BlueZ. The only command is
// Read Controller Information. Never format packets: management can carry keys.
main args/List:
  if args.size != 4: throw "Usage: linux-security-events INDEX ADAPTER_ADDRESS PEER_ADDRESS MGMT_ADDRESS_TYPE"
  adapter := int.parse args[0]
  expected := address args[1]
  peer := address args[2]
  address-type := int.parse args[3]
  if not 0 <= adapter < 0xffff or not 1 <= address-type <= 2: throw "INVALID_ARGUMENT"
  radio := native.NativeTransport.management
  client := linux-management.Client radio adapter
  try:
    info := client.info
    if info.address != expected: throw "MGMT_WRONG_ADAPTER"
    if not info.powered: throw "MGMT_ADAPTER_NOT_POWERED"
    print "MGMT_OBSERVER READY adapter=$adapter"
    connected := 0
    disconnected := 0
    authentication-failed := 0
    selected := 0
    deadline := Time.monotonic-us + 20_000_000
    while Time.monotonic-us < deadline:
      event/List? := null
      failure := catch:
        with-timeout --us=(max 1 (deadline - Time.monotonic-us)):
          event = decode radio.receive adapter peer address-type
      if failure == DEADLINE-EXCEEDED-ERROR: break
      if failure: throw failure
      if not event: continue
      selected++
      if selected > 32: throw "MGMT_OBSERVER_EVENT_LIMIT"
      print "MGMT_OBSERVER event=$(event[0]) detail=$(event[1]) us=$(Time.monotonic-us)"
      if event[0] == 0x000b: connected++
      if event[0] == 0x0011: authentication-failed++
      if event[0] == 0x000c:
        disconnected++
        // Retain late authentication metadata without extending this grace
        // period on duplicate disconnects or unrelated management traffic.
        deadline = min deadline (Time.monotonic-us + 500_000)
    print "MGMT_OBSERVER COMPLETE connected=$connected disconnected=$disconnected authentication-failed=$authentication-failed selected=$selected"
    if connected != 1 or disconnected != 1: throw "MGMT_OBSERVER_INCOMPLETE"
  finally:
    client.close

address text/string -> ByteArray:
  bytes := (hex.decode (text.replace --all ":" "")).reverse
  if bytes.size != 6: throw "INVALID_ARGUMENT"
  return bytes

// BlueZ 5.87 doc/mgmt-protocol.rst: Connected, Disconnected, Connect Failed,
// Authentication Failed. Detail is flags for Connected, otherwise reason/status.
// Only two integers escape; no address, EIR, SMP or key bytes are retained.
decode packet/ByteArray adapter/int peer/ByteArray address-type/int -> List?:
  if packet.size < 6 or (io.LITTLE-ENDIAN.uint16 packet 4) != packet.size - 6:
    throw "MGMT_OBSERVER_MALFORMED"
  if (io.LITTLE-ENDIAN.uint16 packet 2) != adapter: return null
  event := io.LITTLE-ENDIAN.uint16 packet 0
  if not [0x000b, 0x000c, 0x000d, 0x0011].contains event: return null
  if event == 0x000b:
    if packet.size < 19 or (io.LITTLE-ENDIAN.uint16 packet 17) != packet.size - 19:
      throw "MGMT_OBSERVER_MALFORMED"
  else if packet.size != 14:
    throw "MGMT_OBSERVER_MALFORMED"
  if packet[12] != address-type or packet[6..12] != peer: return null
  return [event, event == 0x000b ? (io.LITTLE-ENDIAN.uint32 packet 13) : packet[13]]
