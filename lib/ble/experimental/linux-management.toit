// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import io
import monitor
import .transport show Transport
import .timeouts as timeouts

/** Linux management commands for configuring a test controller under BlueZ. */
class Client:
  transport_/Transport
  adapter_/int
  mutex_/monitor.Mutex ::= monitor.Mutex

  constructor .transport_ .adapter_:
    if not 0 <= adapter_ < 0xffff: throw "INVALID_ARGUMENT"

  /** Reads controller identity and settings without changing them. */
  info -> ControllerInfo:
    bytes := command_ 0x0004 #[]
    if bytes.size != 280: throw "MGMT_INVALID_RESPONSE"
    return ControllerInfo bytes

  /** Sets controller power and returns the resulting settings. */
  set-powered enabled/bool -> int:
    return settings_ (command_ 0x0005 #[enabled ? 1 : 0])

  /**
  Sets privacy using a 16-byte IRK in Bluetooth wire order.

  Requires a powered-off controller. Mode 0 disables privacy; modes 1 and 2
    select the Linux privacy policies. Does not persist or recover the old IRK.
  */
  set-privacy mode/int irk/ByteArray -> int:
    if not 0 <= mode <= 2 or irk.size != 16: throw "INVALID_ARGUMENT"
    return settings_ (command_ 0x002f (#[mode] + irk))

  close -> none:
    transport_.close

  settings_ bytes/ByteArray -> int:
    if bytes.size != 4: throw "MGMT_INVALID_RESPONSE"
    return io.LITTLE-ENDIAN.uint32 bytes 0

  command_ opcode/int parameters/ByteArray -> ByteArray:
    return mutex_.do:
      succeeded := false
      try:
        result := with-timeout timeouts.MANAGEMENT:
          request := ByteArray (6 + parameters.size)
          io.LITTLE-ENDIAN.put-uint16 request 0 opcode
          io.LITTLE-ENDIAN.put-uint16 request 2 adapter_
          io.LITTLE-ENDIAN.put-uint16 request 4 parameters.size
          request.replace 6 parameters
          transport_.send request
          receive_ opcode
        succeeded = true
        return result
      finally:
        // A timed-out or interrupted command must not leave a response that
        // could be mistaken for a subsequent command's response.
        if not succeeded: close

  receive_ opcode/int -> ByteArray:
    while true:
      packet := transport_.receive
      if packet.size < 6 or (io.LITTLE-ENDIAN.uint16 packet 4) != packet.size - 6:
        throw "MGMT_INVALID_RESPONSE"
      if (io.LITTLE-ENDIAN.uint16 packet 2) != adapter_: continue
      event := io.LITTLE-ENDIAN.uint16 packet 0
      if event != 1 and event != 2: continue
      if packet.size < 9: throw "MGMT_INVALID_RESPONSE"
      if (io.LITTLE-ENDIAN.uint16 packet 6) != opcode: continue
      if packet[8] != 0: throw "MGMT_STATUS_$(packet[8])"
      if event != 1: throw "MGMT_INVALID_RESPONSE"
      return packet[9..].copy
    unreachable

/** An owned snapshot of Linux's controller information. */
class ControllerInfo:
  bytes_/ByteArray

  constructor .bytes_:

  address -> ByteArray: return bytes_[0..6].copy
  supported-settings -> int: return io.LITTLE-ENDIAN.uint32 bytes_ 9
  settings -> int: return io.LITTLE-ENDIAN.uint32 bytes_ 13
  powered -> bool: return settings & 1 != 0
  privacy -> bool: return settings & (1 << 13) != 0
