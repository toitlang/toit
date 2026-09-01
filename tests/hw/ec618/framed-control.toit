// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import crypto.crc
import uart

MAGIC-0 ::= 0xa5
MAGIC-1 ::= 0x5a
HEADER-SIZE ::= 3
CHECKSUM-SIZE ::= 2
MAX-PAYLOAD-SIZE ::= 255

/**
Encodes a short test-control message as a self-synchronizing frame.

The wire format is:

```
0xa5 0x5a <one-byte payload length> <payload> <CRC-16/XMODEM, big endian>
```

The checksum covers the length byte and payload. The two-byte marker lets the
  decoder discard UART boot output or an incomplete frame and find the next
  valid message.
*/
encode-frame payload/string -> ByteArray:
  bytes := payload.to-byte-array
  if bytes.size > MAX-PAYLOAD-SIZE: throw "control payload is too large"
  frame := ByteArray HEADER-SIZE + bytes.size + CHECKSUM-SIZE
  frame[0] = MAGIC-0
  frame[1] = MAGIC-1
  frame[2] = bytes.size
  frame.replace HEADER-SIZE bytes
  checksum := crc.crc16-xmodem frame[2 .. HEADER-SIZE + bytes.size]
  frame[HEADER-SIZE + bytes.size] = checksum >> 8
  frame[HEADER-SIZE + bytes.size + 1] = checksum & 0xff
  return frame

/**
Incrementally decodes control frames from arbitrarily chunked UART input.
*/
class FrameDecoder:
  pending_/ByteArray := #[]

  add bytes/ByteArray -> none:
    pending_ += bytes

  /**
  Returns the next valid payload, or null if more input is required.

  Junk and checksum-invalid candidates are skipped while retaining a possible
    leading marker byte for the next input chunk.
  */
  take -> string?:
    while true:
      marker := find-marker_
      if marker < 0:
        pending_ = pending_.size > 0 and pending_[pending_.size - 1] == MAGIC-0
            ? #[MAGIC-0]
            : #[]
        return null
      if marker > 0: pending_ = pending_[marker ..]
      if pending_.size < HEADER-SIZE: return null

      payload-size := pending_[2]
      frame-size := HEADER-SIZE + payload-size + CHECKSUM-SIZE
      if pending_.size < frame-size: return null

      expected := (pending_[frame-size - 2] << 8) | pending_[frame-size - 1]
      actual := crc.crc16-xmodem pending_[2 .. HEADER-SIZE + payload-size]
      if actual != expected:
        pending_ = pending_[1 ..]
        continue

      payload := pending_[HEADER-SIZE .. HEADER-SIZE + payload-size]
      pending_ = pending_[frame-size ..]
      return payload.to-string-non-throwing

  find-marker_ -> int:
    for i := 0; i + 1 < pending_.size; i++:
      if pending_[i] == MAGIC-0 and pending_[i + 1] == MAGIC-1: return i
    return -1

/**
A framed command channel over an already-owned UART port.
*/
class FramedChannel:
  port/uart.Port
  decoder_/FrameDecoder := FrameDecoder

  constructor .port:

  send payload/string -> none:
    port.out.write (encode-frame payload)
    port.out.flush

  receive --timeout-ms/int -> string:
    with-timeout --ms=timeout-ms:
      while true:
        result := decoder_.take
        if result != null: return result
        chunk := port.in.read
        if not chunk: throw "control UART closed"
        decoder_.add chunk
    unreachable

  expect expected/string --timeout-ms/int -> none:
    actual := receive --timeout-ms=timeout-ms
    if actual != expected:
      throw "expected control reply '$expected', got '$actual'"
