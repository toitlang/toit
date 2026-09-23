// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import io
import .hci as hci

/** A controller-reported encryption procedure failure. */
class Error:
  status/int

  constructor .status:

  stringify -> string: return "HCI_ENCRYPTION_FAILED status=$status"

/** A controller encryption/change result; this does not establish MITM authentication. */
class Change:
  status/int
  handle/int
  enabled/bool
  refresh/bool

  constructor .status .handle .enabled --refresh/bool=false:
    this.refresh = refresh

/** Decodes LE Encryption Change v1/v2 or Encryption Key Refresh Complete. */
decode-change packet/ByteArray -> Change?:
  hci.validate-packet packet
  if packet[0] != 4: return null
  code := packet[1]
  if code != 8 and code != 0x59 and code != 0x30: return null
  length := code == 0x30 ? 6 : (code == 8 ? 7 : 8)
  if packet.size != length: throw "HCI_MALFORMED_ENCRYPTION_EVENT"
  handle := io.LITTLE-ENDIAN.uint16 packet 4
  if handle > 0x0eff: throw "HCI_MALFORMED_ENCRYPTION_EVENT"
  if packet[3] != 0: return Change packet[3] handle false --refresh=(code == 0x30)
  if code == 0x30: return Change 0 handle true --refresh
  // Encryption_Enabled=2 is BR/EDR-only. The v2 key-size field is ignored on LE.
  if packet[6] > 1: throw "HCI_MALFORMED_ENCRYPTION_EVENT"
  return Change 0 handle (packet[6] == 1)

/** A peripheral controller's key request, with owned public lookup metadata. */
class KeyRequest:
  handle/int
  random/ByteArray
  ediv/int

  constructor .handle .random .ediv:

  /** Tests the zero Rand/EDIV required for Secure Connections. */
  secure-connections -> bool:
    if ediv != 0: return false
    random.do: if it != 0: return false
    return true

/** Decodes LE Long Term Key Request (Core 6.3 Vol 4 Part E, 7.7.65.5). */
decode-key-request packet/ByteArray -> KeyRequest?:
  hci.validate-packet packet
  if packet[0] != 4 or packet[1] != 0x3e: return null
  if packet.size < 4: throw "HCI_MALFORMED_ENCRYPTION_EVENT"
  if packet[3] != 5: return null
  if packet.size != 16: throw "HCI_MALFORMED_ENCRYPTION_EVENT"
  handle := io.LITTLE-ENDIAN.uint16 packet 4
  if handle > 0x0eff: throw "HCI_MALFORMED_ENCRYPTION_EVENT"
  return KeyRequest handle packet[6..14].copy (io.LITTLE-ENDIAN.uint16 packet 14)

/**
Encodes LE Enable Encryption parameters for a big-endian LTK (7.8.24).

SC keys use the zero $random and $ediv defaults; a legacy bond passes the
  values its peer distributed with the key.
*/
enable-parameters handle/int key/ByteArray --random/ByteArray?=null --ediv/int=0 -> ByteArray:
  check_ handle key
  if random and random.size != 8: throw "INVALID_ARGUMENT"
  if not 0 <= ediv <= 0xffff: throw "INVALID_ARGUMENT"
  result := ByteArray 28
  io.LITTLE-ENDIAN.put-uint16 result 0 handle
  if random: result.replace 2 random
  io.LITTLE-ENDIAN.put-uint16 result 10 ediv
  // The HCI LTK is least-significant-octet first.
  16.repeat: result[12 + it] = key[15 - it]
  return result

/** Encodes LE Long Term Key Request Reply for a big-endian LTK (7.8.25). */
reply-parameters handle/int key/ByteArray -> ByteArray:
  check_ handle key
  result := ByteArray 18
  io.LITTLE-ENDIAN.put-uint16 result 0 handle
  16.repeat: result[2 + it] = key[15 - it]
  return result

/** Encodes LE Long Term Key Request Negative Reply (7.8.26). */
negative-parameters handle/int -> ByteArray:
  if not 0 <= handle <= 0x0eff: throw "INVALID_ARGUMENT"
  result := ByteArray 2
  io.LITTLE-ENDIAN.put-uint16 result 0 handle
  return result

check_ handle/int key/ByteArray -> none:
  if not 0 <= handle <= 0x0eff or key.size != 16: throw "INVALID_ARGUMENT"
