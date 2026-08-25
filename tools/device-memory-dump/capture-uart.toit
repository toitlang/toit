// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import host.file
import io
import uart

SYNC ::= #[0x54, 0x44, 0x4d, 0x31]
HEADER-SIZE ::= 24
TRAILER-SIZE ::= 4
END-FRAME ::= 3
MAX-PAYLOAD-SIZE ::= 2_048

main args/List:
  if args.size != 2:
    print "Usage: capture-uart PORT OUTPUT.bin"
    throw "INVALID_ARGUMENTS"

  port := uart.HostPort args[0] --baud-rate=115_200
  captured := io.Buffer
  scan-offset := 0
  complete := false
  try:
    port.set-control-flag uart.HostPort.CONTROL-FLAG-DTR false
    port.set-control-flag uart.HostPort.CONTROL-FLAG-RTS false
    while not complete:
      data := port.in.read
      if not data: throw "SERIAL_PORT_CLOSED"
      captured.write data
      bytes := captured.bytes
      while scan-offset + HEADER-SIZE <= bytes.size:
        if not is-sync bytes scan-offset:
          scan-offset++
          continue
        payload-size := io.LITTLE-ENDIAN.uint32 bytes (scan-offset + 20)
        if payload-size > MAX-PAYLOAD-SIZE:
          scan-offset++
          continue
        frame-size := HEADER-SIZE + payload-size + TRAILER-SIZE
        if scan-offset + frame-size > bytes.size: break
        if bytes[scan-offset + 4] == END-FRAME:
          complete = true
          break
        scan-offset += frame-size
  finally:
    port.close

  file.write-contents --path=args[1] captured.bytes
  print "Captured $(captured.size) UART bytes in $(args[1])"

is-sync bytes/ByteArray offset/int -> bool:
  return bytes[offset] == SYNC[0] and
      bytes[offset + 1] == SYNC[1] and
      bytes[offset + 2] == SYNC[2] and
      bytes[offset + 3] == SYNC[3]
