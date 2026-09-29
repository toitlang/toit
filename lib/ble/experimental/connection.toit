// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import io

import .hci as hci

/** Encodes legacy LE connection parameters (Core 6.3, 7.8.12). */
create-parameters address/ByteArray --address-type/int --own-address-type/int=0 -> ByteArray:
  // Address types 0 and 1 are on-air addresses; 2 and 3 are the identity of a
  // peer in the controller's resolving list (resolving-list.toit), which the
  // controller finds by its current resolvable private address.
  if address.size != 6 or not 0 <= address-type <= 3: throw "INVALID_ARGUMENT"
  if not 0 <= own-address-type <= 1: throw "INVALID_ARGUMENT"
  result := ByteArray 25
  io.LITTLE-ENDIAN.put-uint16 result 0 0x10
  io.LITTLE-ENDIAN.put-uint16 result 2 0x10
  result[5] = address-type
  result.replace 6 address
  result[12] = own-address-type
  // 30-50 ms interval, no latency, 4 s supervision.
  io.LITTLE-ENDIAN.put-uint16 result 13 24
  io.LITTLE-ENDIAN.put-uint16 result 15 40
  io.LITTLE-ENDIAN.put-uint16 result 19 400
  return result

/**
An LE connection completion, including failed procedures.

$address is the peer's address on air. When the controller resolved it from
  its resolving list, $identity-address and $identity-address-type give the
  peer's identity; otherwise they are null.
*/
class Completion:
  status/int
  handle/int
  address-type/int
  address/ByteArray
  interval/int
  latency/int
  supervision-timeout/int
  role/int
  identity-address/ByteArray?
  identity-address-type/int?

  constructor .status .handle .address-type .address .interval .latency .supervision-timeout --role/int=0
      --.identity-address=null --.identity-address-type=null:
    this.role = role

/**
Decodes a legacy connection completion for the expected role, or returns null.

Failed completions do not have meaningful connection parameters. Their fields
  are cleared, leaving only status. Role zero is central; role one is peripheral.
*/
decode-completion packet/ByteArray --role/int=0 -> Completion?:
  if role != 0 and role != 1: throw "INVALID_ARGUMENT"
  hci.validate-packet packet
  if packet[0] != 4 or packet[1] != 0x3e: return null
  if packet.size < 4: throw "HCI_MALFORMED_CONNECTION_EVENT"
  if packet[3] == 0x0a: return decode-enhanced-completion packet --role=role
  if packet[3] != 1: return null
  if packet.size != 22: throw "HCI_MALFORMED_CONNECTION_EVENT"
  status := packet[4]
  if status != 0: return Completion status 0 0 #[] 0 0 0
  handle := io.LITTLE-ENDIAN.uint16 packet 5
  if handle > 0x0eff or packet[8] > 1: throw "HCI_MALFORMED_CONNECTION_EVENT"
  if packet[7] != role: throw "HCI_UNEXPECTED_CONNECTION_ROLE"
  interval := io.LITTLE-ENDIAN.uint16 packet 15
  latency := io.LITTLE-ENDIAN.uint16 packet 17
  timeout := io.LITTLE-ENDIAN.uint16 packet 19
  if not 6 <= interval <= 3200 or not 0 <= latency <= 499 or
      not 10 <= timeout <= 3200 or timeout * 4 <= (latency + 1) * interval:
    throw "HCI_MALFORMED_CONNECTION_EVENT"
  return Completion status handle packet[8] packet[9..15] interval latency timeout --role=role

/**
Decodes LE Enhanced Connection Complete v1 (Vol 4 Part E 7.7.65.10).

A resolved peer (address type 2 or 3) reports its identity; its on-air
  address is the peer resolvable private address, or the identity itself
  when the peer used that on air.
*/
decode-enhanced-completion packet/ByteArray --role/int=0 -> Completion?:
  if role != 0 and role != 1: throw "INVALID_ARGUMENT"
  hci.validate-packet packet
  if packet[0] != 4 or packet[1] != 0x3e or packet.size < 4 or packet[3] != 0x0a: return null
  if packet.size != 34: throw "HCI_MALFORMED_CONNECTION_EVENT"
  status := packet[4]
  if status != 0: return Completion status 0 0 #[] 0 0 0
  handle := io.LITTLE-ENDIAN.uint16 packet 5
  type := packet[8]
  if handle > 0x0eff or type > 3: throw "HCI_MALFORMED_CONNECTION_EVENT"
  if packet[7] != role: throw "HCI_UNEXPECTED_CONNECTION_ROLE"
  interval := io.LITTLE-ENDIAN.uint16 packet 27
  latency := io.LITTLE-ENDIAN.uint16 packet 29
  timeout := io.LITTLE-ENDIAN.uint16 packet 31
  if not 6 <= interval <= 3200 or not 0 <= latency <= 499 or
      not 10 <= timeout <= 3200 or timeout * 4 <= (latency + 1) * interval:
    throw "HCI_MALFORMED_CONNECTION_EVENT"
  address := packet[9..15].copy
  peer-rpa := packet[21..27]
  resolved-rpa := peer-rpa.any: it != 0
  if type < 2:
    if resolved-rpa: throw "HCI_MALFORMED_CONNECTION_EVENT"
    return Completion status handle type address interval latency timeout --role=role
  identity-type := type - 2
  on-air := resolved-rpa ? peer-rpa.copy : address
  return Completion status handle (resolved-rpa ? 1 : identity-type) on-air interval latency timeout
      --role=role
      --identity-address=address
      --identity-address-type=identity-type

/** A disconnection completion, including a possible controller rejection. */
class Disconnection:
  status/int
  handle/int
  reason/int

  constructor .status .handle .reason:

/** Decodes Disconnection Complete (Core 6.3, Vol 4 Part E, 7.7.5). */
decode-disconnection packet/ByteArray -> Disconnection?:
  hci.validate-packet packet
  if packet[0] != 4 or packet[1] != 5: return null
  if packet.size != 7: throw "HCI_MALFORMED_CONNECTION_EVENT"
  handle := io.LITTLE-ENDIAN.uint16 packet 4
  if handle > 0x0eff: throw "HCI_MALFORMED_CONNECTION_EVENT"
  return Disconnection packet[3] handle packet[6]

/** Encodes a local disconnect with Remote User Terminated Connection reason. */
disconnect-parameters handle/int -> ByteArray:
  if not 0 <= handle <= 0x0eff: throw "INVALID_ARGUMENT"
  result := ByteArray 3
  io.LITTLE-ENDIAN.put-uint16 result 0 handle
  result[2] = 0x13
  return result

/** The controller's result of a connection parameter update. */
class Update:
  status/int
  handle/int
  interval/int
  latency/int
  supervision-timeout/int

  constructor .status .handle .interval .latency .supervision-timeout:

/** Decodes LE Connection Update Complete (Vol 4 Part E, 7.7.65.3). */
decode-update packet/ByteArray -> Update?:
  hci.validate-packet packet
  if packet[0] != 4 or packet[1] != 0x3e: return null
  if packet.size < 4: throw "HCI_MALFORMED_CONNECTION_EVENT"
  if packet[3] != 3: return null
  if packet.size != 13: throw "HCI_MALFORMED_CONNECTION_EVENT"
  handle := io.LITTLE-ENDIAN.uint16 packet 5
  if handle > 0x0eff: throw "HCI_MALFORMED_CONNECTION_EVENT"
  if packet[4] != 0: return Update packet[4] handle 0 0 0
  interval := io.LITTLE-ENDIAN.uint16 packet 7
  latency := io.LITTLE-ENDIAN.uint16 packet 9
  timeout := io.LITTLE-ENDIAN.uint16 packet 11
  if not 6 <= interval <= 3200 or not 0 <= latency <= 499 or
      not 10 <= timeout <= 3200 or timeout * 4 <= (latency + 1) * interval:
    throw "HCI_MALFORMED_CONNECTION_EVENT"
  return Update 0 handle interval latency timeout

/** Encodes LE Connection Update (Vol 4 Part E, 7.8.18). */
update-parameters handle/int --interval-min/int --interval-max/int
    --latency/int=0 --supervision-timeout/int=400 -> ByteArray:
  if not 0 <= handle <= 0x0eff or not 6 <= interval-min <= interval-max <= 3200 or
      not 0 <= latency <= 499 or not 10 <= supervision-timeout <= 3200 or
      supervision-timeout * 4 <= (latency + 1) * interval-max:
    throw "INVALID_ARGUMENT"
  bytes := ByteArray 14
  io.LITTLE-ENDIAN.put-uint16 bytes 0 handle
  io.LITTLE-ENDIAN.put-uint16 bytes 2 interval-min
  io.LITTLE-ENDIAN.put-uint16 bytes 4 interval-max
  io.LITTLE-ENDIAN.put-uint16 bytes 6 latency
  io.LITTLE-ENDIAN.put-uint16 bytes 8 supervision-timeout
  return bytes

/**
Validates and copies a host-selected static random or resolvable private address.

The six bytes use HCI order. Non-resolvable private addresses are unsupported
  here; their additional comparison with the public address requires that identity.
*/
random-address bytes/ByteArray -> ByteArray:
  if bytes.size != 6: throw "INVALID_ARGUMENT"
  kind := bytes[5] & 0xc0
  if kind != 0x40 and kind != 0xc0: throw "INVALID_ARGUMENT"
  start := kind == 0x40 ? 3 : 0
  all-zero := (bytes[5] & 0x3f) == 0
  all-one := (bytes[5] & 0x3f) == 0x3f
  for i := start; i < 5; i++:
    all-zero = all-zero and bytes[i] == 0
    all-one = all-one and bytes[i] == 255
  if all-zero or all-one: throw "INVALID_ARGUMENT"
  return bytes.copy

/** The link-layer payload lengths and times in effect after a length update. */
class DataLength:
  handle/int
  tx-octets/int
  tx-time/int
  rx-octets/int
  rx-time/int

  constructor .handle .tx-octets .tx-time .rx-octets .rx-time:

/** Decodes LE Data Length Change (Vol 4 Part E, 7.7.65.7). */
decode-data-length packet/ByteArray -> DataLength?:
  hci.validate-packet packet
  if packet[0] != 4 or packet[1] != 0x3e: return null
  if packet.size < 4: throw "HCI_MALFORMED_CONNECTION_EVENT"
  if packet[3] != 7: return null
  if packet.size != 14: throw "HCI_MALFORMED_CONNECTION_EVENT"
  handle := io.LITTLE-ENDIAN.uint16 packet 4
  if handle > 0x0eff: throw "HCI_MALFORMED_CONNECTION_EVENT"
  tx-octets := io.LITTLE-ENDIAN.uint16 packet 6
  tx-time := io.LITTLE-ENDIAN.uint16 packet 8
  rx-octets := io.LITTLE-ENDIAN.uint16 packet 10
  rx-time := io.LITTLE-ENDIAN.uint16 packet 12
  if not 27 <= tx-octets <= 251 or not 27 <= rx-octets <= 251 or
      not 328 <= tx-time <= 17040 or not 328 <= rx-time <= 17040:
    throw "HCI_MALFORMED_CONNECTION_EVENT"
  return DataLength handle tx-octets tx-time rx-octets rx-time

/** The PHYs in effect on a link after a PHY update. */
class Phy:
  static PHY-1M ::= 1
  static PHY-2M ::= 2
  static PHY-CODED ::= 3
  handle/int
  tx/int
  rx/int

  constructor .handle .tx .rx:

/**
Encodes LE Set PHY with preference masks (Vol 4 Part E, 7.8.49).

Bit 0 is 1M, bit 1 is 2M and bit 2 is Coded in both $tx and $rx; each needs
  at least one bit. Coded PHY options are left to the controller.
*/
phy-parameters handle/int --tx/int --rx/int -> ByteArray:
  if not 0 <= handle <= 0x0eff or not 1 <= tx <= 7 or not 1 <= rx <= 7: throw "INVALID_ARGUMENT"
  result := ByteArray 7
  io.LITTLE-ENDIAN.put-uint16 result 0 handle
  result[3] = tx
  result[4] = rx
  return result

/**
Decodes a failed LE PHY Update Complete as [handle, status], or null.

$decode-phy-update returns null for these; a host-initiated request needs
  the status to finish.
*/
decode-phy-update-failure packet/ByteArray -> List?:
  hci.validate-packet packet
  if packet[0] != 4 or packet[1] != 0x3e or packet.size != 9 or packet[3] != 0x0c: return null
  if packet[4] == 0: return null
  handle := io.LITTLE-ENDIAN.uint16 packet 5
  if handle > 0x0eff: throw "HCI_MALFORMED_CONNECTION_EVENT"
  return [handle, packet[4]]

/** Encodes LE Set PHY asking for 2M in both directions (Vol 4 Part E, 7.8.49). */
phy-2m-parameters handle/int -> ByteArray:
  if not 0 <= handle <= 0x0eff: throw "INVALID_ARGUMENT"
  result := ByteArray 7
  io.LITTLE-ENDIAN.put-uint16 result 0 handle
  result[3] = 0x02
  result[4] = 0x02
  return result

/** Decodes LE PHY Update Complete (Vol 4 Part E, 7.7.65.12). */
decode-phy-update packet/ByteArray -> Phy?:
  hci.validate-packet packet
  if packet[0] != 4 or packet[1] != 0x3e: return null
  if packet.size < 4: throw "HCI_MALFORMED_CONNECTION_EVENT"
  if packet[3] != 0x0c: return null
  if packet.size != 9: throw "HCI_MALFORMED_CONNECTION_EVENT"
  if packet[4] != 0: return null
  handle := io.LITTLE-ENDIAN.uint16 packet 5
  if handle > 0x0eff or not 1 <= packet[7] <= 3 or not 1 <= packet[8] <= 3:
    throw "HCI_MALFORMED_CONNECTION_EVENT"
  return Phy handle packet[7] packet[8]

/** The peer's LE features, or a controller status when the exchange failed. */
class Features:
  status/int
  handle/int
  bytes/ByteArray

  constructor .status .handle .bytes:

/** Encodes LE Read Remote Features (Vol 4 Part E, 7.8.21). */
features-parameters handle/int -> ByteArray:
  if not 0 <= handle <= 0x0eff: throw "INVALID_ARGUMENT"
  result := ByteArray 2
  io.LITTLE-ENDIAN.put-uint16 result 0 handle
  return result

/** Decodes LE Read Remote Features Complete (Vol 4 Part E, 7.7.65.4). */
decode-features packet/ByteArray -> Features?:
  hci.validate-packet packet
  if packet[0] != 4 or packet[1] != 0x3e: return null
  if packet.size < 4: throw "HCI_MALFORMED_CONNECTION_EVENT"
  if packet[3] != 4: return null
  if packet.size != 15: throw "HCI_MALFORMED_CONNECTION_EVENT"
  handle := io.LITTLE-ENDIAN.uint16 packet 5
  if handle > 0x0eff: throw "HCI_MALFORMED_CONNECTION_EVENT"
  return Features packet[4] handle (packet[4] == 0 ? packet[7..15].copy : #[])

