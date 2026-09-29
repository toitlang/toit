// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import io

/** Encodes a peripheral Connection Parameter Update Request (section 4.20). */
parameter-request identifier/int --interval/int=12 --interval-max/int=interval --latency/int=0
    --supervision-timeout/int=400 -> ByteArray:
  if not 1 <= identifier <= 255 or not 6 <= interval <= interval-max <= 3200 or
      not 0 <= latency <= 499 or not 10 <= supervision-timeout <= 3200 or
      supervision-timeout * 4 <= (latency + 1) * interval-max:
    throw "INVALID_ARGUMENT"
  result := #[0x12, identifier, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0]
  io.LITTLE-ENDIAN.put-uint16 result 4 interval
  io.LITTLE-ENDIAN.put-uint16 result 6 interval-max
  io.LITTLE-ENDIAN.put-uint16 result 8 latency
  io.LITTLE-ENDIAN.put-uint16 result 10 supervision-timeout
  return result

/** Decodes Update Response or Command Reject; null means an unrelated PDU. */
parameter-response bytes/ByteArray identifier/int -> int?:
  if bytes.size < 2: throw "L2CAP_INVALID_SIGNALING"
  if bytes[1] != identifier: return null
  if bytes[0] == 1:
    if bytes.size < 6: throw "L2CAP_INVALID_SIGNALING"
    reason := io.LITTLE-ENDIAN.uint16 bytes 4
    if reason > 2 or bytes.size != 6 + reason * 2 or
        (io.LITTLE-ENDIAN.uint16 bytes 2) != bytes.size - 4:
      throw "L2CAP_INVALID_SIGNALING"
    return 1
  if bytes[0] != 0x13: return null
  if bytes.size != 6 or bytes[2] != 2 or bytes[3] != 0 or
      bytes[4] > 1 or bytes[5] != 0:
    throw "L2CAP_INVALID_SIGNALING"
  return bytes[4]

/**
Responds to LE signaling with the default fixed-channel policy for the selected role.

Rejects connection-parameter changes and unsupported commands. Unsolicited known
  responses and identifier zero are ignored. Supports MTUsig 23. See Core 6.3
  Vol 3 Part A sections 4, 4.1 and 4.20–4.21.
*/
response bytes/ByteArray --peripheral/bool=false -> ByteArray?:
  if bytes.size < 4: throw "L2CAP_INVALID_SIGNALING"
  code := bytes[0]
  identifier := bytes[1]
  if identifier == 0: return null
  if bytes.size != 4 + (io.LITTLE-ENDIAN.uint16 bytes 2):
    throw "L2CAP_INVALID_SIGNALING"
  if code == 1 or code == 3 or code == 5 or code == 7 or code == 9 or
      code == 11 or code == 0x13 or code == 0x15 or code == 0x18 or code == 0x1a:
    return null
  if bytes.size > 23: return #[1, identifier, 4, 0, 1, 0, 23, 0]
  if code == 0x12:
    // Only a peripheral may initiate this procedure (Core 6.3, 4.20).
    if peripheral: return #[1, identifier, 2, 0, 0, 0]
    if bytes.size != 12: throw "L2CAP_INVALID_SIGNALING"
    return #[0x13, identifier, 2, 0, 1, 0]
  return #[1, identifier, 2, 0, 0, 0]

/** Rejects pairing with Pairing Not Supported (Core 6.3 Vol 3 Part H, 3.3/3.5.5). */
security-response bytes/ByteArray -> ByteArray?:
  if bytes.is-empty: throw "SMP_INVALID_PDU"
  // Core 6.3, Vol 3, Part H, 3.3 requires ignoring reserved command codes,
  // including when pairing is disabled. Do not turn them into a failure.
  if bytes[0] == 0 or bytes[0] > 0x0e: return null
  // A peer's failure ends its procedure; do not start a failure-response loop.
  if bytes[0] == 5: return null
  return #[5, 5]

/** A structurally valid peer connection-parameter request. */
class ParameterRequest:
  identifier/int
  interval-min/int
  interval-max/int
  latency/int
  supervision-timeout/int

  constructor .identifier .interval-min .interval-max .latency .supervision-timeout:

  /** Tests the controller's permitted range and supervision relationship. */
  valid -> bool:
    return 6 <= interval-min <= interval-max <= 3200 and
        0 <= latency <= 499 and 10 <= supervision-timeout <= 3200 and
        supervision-timeout * 4 > (latency + 1) * interval-max

/** Parses a peer update request; null means another signaling command. */
decode-parameter-request bytes/ByteArray -> ParameterRequest?:
  if bytes.size < 4: throw "L2CAP_INVALID_SIGNALING"
  if bytes[1] == 0: return null
  if bytes.size != 4 + (io.LITTLE-ENDIAN.uint16 bytes 2):
    throw "L2CAP_INVALID_SIGNALING"
  if bytes[0] != 0x12: return null
  if bytes.size != 12: throw "L2CAP_INVALID_SIGNALING"
  return ParameterRequest bytes[1]
      (io.LITTLE-ENDIAN.uint16 bytes 4)
      (io.LITTLE-ENDIAN.uint16 bytes 6)
      (io.LITTLE-ENDIAN.uint16 bytes 8)
      (io.LITTLE-ENDIAN.uint16 bytes 10)
