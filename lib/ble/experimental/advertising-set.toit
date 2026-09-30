// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can
// be found in the lib/LICENSE file.

import io

/**
Parameter encoders for legacy advertising.

$parameters builds the advertising-parameters command payload and $data the
  31-byte advertising or scan-response payload. The link owner's accept
  procedure and the advertising provider use them to start advertising over
  the HCI controller; neither function sends anything itself.
*/

/** Encodes undirected legacy advertising with an explicit public/random local type. */
parameters --interval/int=160 --own-address-type/int=0 --type/int=0 -> ByteArray:
  if not 0x20 <= interval <= 0x4000: throw "INVALID_ARGUMENT"
  if not 0 <= own-address-type <= 1: throw "INVALID_ARGUMENT"
  if type != 0 and type != 2 and type != 3: throw "INVALID_ARGUMENT"
  result := ByteArray 15
  io.LITTLE-ENDIAN.put-uint16 result 0 interval
  io.LITTLE-ENDIAN.put-uint16 result 2 interval
  result[4] = type
  result[5] = own-address-type
  result[13] = 7
  return result

/** Encodes up to 31 bytes of advertising or scan-response data. */
data bytes/ByteArray -> ByteArray:
  if bytes.size > 31: throw "INVALID_ARGUMENT"
  result := ByteArray 32
  result[0] = bytes.size
  result.replace 1 bytes
  return result
