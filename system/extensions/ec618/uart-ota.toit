// Copyright (C) 2026 Toit contributors.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

import ec618 show Ec618
import ec618.slot
import io
import uart

/**
Dual-slot OTA receiver — request/ack protocol over UART1.

The host drives every step; the device only acts after being told
  to. This both flow-controls the transfer (we have no hardware flow
  control on UART1) and gives the operator a clear progress signal
  each step of the way.

Wire protocol (all bytes, no framing — host knows what it asked for):

```
host : 'P'                       ping
dev  : 'P'

host : 'I'                       which slot is active?
dev  : 'A' or 'B'

host : 'E'                       erase the inactive slot (~7 s)
dev  : 'K'  (ok)  or 'X'  (fail)

host : 'W'<off:4 BE><len:4 BE>   prepare to receive len bytes
dev  : 'R'                       ready, send the payload
host : <len bytes>
dev  : 'K' or 'X'                after flash write

host : 'S'                       set inactive-slot byte + reset
dev  : 'K'                       (and reboots immediately)
```

`len` for write must be a multiple of 16 (flash segment size). `off`
  must be aligned the same way and fit inside the slot. Sensible chunk
  size is 4 KB — one sector worth, big enough to amortise the per-write
  flash-controller overhead, small enough to fit in the 2 KB RX buffer
  twice over.

Status / debug strings are emitted on the same TX path; they're
  human-readable and end with `\n` so the host can tee them to a log
  without parsing.
*/

CMD-PING       ::= 'P'
CMD-INFO       ::= 'I'
CMD-TRIAL      ::= 'T'
CMD-ERASE      ::= 'E'
CMD-WRITE      ::= 'W'
CMD-STAGE      ::= 'S'   // Stage the written slot as a trial + reset.
CMD-VALIDATE   ::= 'V'   // Confirm the running slot (cancel rollback).
CMD-INVALIDATE ::= 'N'   // Reject the running slot + reset (rollback now).
ACK-OK         ::= 'K'
ACK-READY      ::= 'R'
ACK-ERROR      ::= 'X'

main:
  // fw program/erase mode: required for ANY write into the protected
  // AP-image region (the inactive slot). The SDK FOTA sets this (via
  // luat_flash_ctrl_fw_sectors) before writing firmware there. Without
  // it, slot writes reset the chip almost immediately even modem-off.
  slot.program-mode 1
  // Modem OFF for the duration of the OTA. This is currently REQUIRED:
  // with the modem on, sustained AP flash+UART activity resets the chip
  // after ~3-4 s because it misses a CP real-time deadline. A full UART OTA
  // takes ~34 s, so it can't run modem-on yet. TEST-ONLY for a UART
  // transport; a cellular OTA would need the modem up (open work).
  modem-rc := slot.modem-set-function 0
  print "[ota] modem off (appSetCFUN 0) rc=$modem-rc"
  port := Ec618.uart1 --baud-rate=115200
  reader := port.in
  out := port.out
  out.write "\n[ota] ready, active=$(string.from-rune slot.active)\n"
  try:
    loop reader out
  finally:
    port.close

loop reader/io.Reader out/io.Writer -> none:
  while true:
    // Use the buffered reader API: read-byte / read-bytes / the
    // big-endian helper all keep leftover bytes in the reader's buffer.
    // (The old hand-rolled reader discarded everything past the first
    // byte of a chunk, which dropped the 8-byte header the host sends
    // together with the 'W' command.)
    cmd-byte := reader.read-byte
    if      cmd-byte == CMD-PING:       ping  out
    else if cmd-byte == CMD-INFO:       info  out
    else if cmd-byte == CMD-TRIAL:      trial-info out
    else if cmd-byte == CMD-ERASE:      erase out
    else if cmd-byte == CMD-WRITE:      write reader out
    else if cmd-byte == CMD-STAGE:      stage out
    else if cmd-byte == CMD-VALIDATE:   validate out
    else if cmd-byte == CMD-INVALIDATE: invalidate out
    else:
      out.write "[ota] unknown cmd 0x$(%02x cmd-byte); continuing\n"

ping out/io.Writer -> none:
  out.write #[CMD-PING]

info out/io.Writer -> none:
  byte := slot.active
  out.write (ByteArray 1 --initial=byte)
  out.write "[ota] INFO: active=$(string.from-rune byte) trial=$slot.trial\n"

// Reports whether the running slot is an unconfirmed trial: 'Y' or 'N'.
trial-info out/io.Writer -> none:
  byte := slot.trial ? 'Y' : 'N'
  out.write (ByteArray 1 --initial=byte)
  out.write "[ota] TRIAL: $(string.from-rune byte)\n"

// No bulk-erase phase: a 96-sector back-to-back erase is ~3.6 s of
// uninterrupted flash, which (modem on) starves the CP past its ~3.7 s
// deadline and resets the chip — even in firmware program/erase mode.
// Instead each chunk's sectors are erased inside WRITE, so the per-chunk
// request/ack breaks (the device blocks on UART RX between chunks, AP
// idle, CP serviced) keep the CP alive across the whole transfer.
erase out/io.Writer -> none:
  out.write "[ota] ERASE: per-chunk (no bulk erase)\n"
  out.write #[ACK-OK]

write reader/io.Reader out/io.Writer -> none:
  // Header: off:4 BE, len:4 BE. The big-endian helper reads from the
  // reader's internal buffer, so the header bytes the host sent in the
  // same write as the 'W' command are still here.
  be := reader.big-endian
  off := be.read-uint32
  len := be.read-uint32
  out.write "[ota] WRITE: off=0x$(%08x off) len=$len\n"
  out.write #[ACK-READY]
  // read-bytes blocks until exactly `len` bytes have arrived, across
  // however many USB/UART chunks that takes.
  payload := reader.read-bytes len
  e := catch:
    // Erase every sector this chunk covers, then write. Modem stays on;
    // fw program/erase mode (set in main) makes AP-image writes CP-safe,
    // and the per-chunk protocol break afterwards services the CP.
    sector-start := off - (off % slot.SECTOR-SIZE)
    end := off + len
    s := sector-start
    while s < end:
      slot.erase-inactive-sector s
      s += slot.SECTOR-SIZE
    slot.write-inactive off payload
  if e:
    out.write "[ota] WRITE: flash write failed: $e\n"
    out.write #[ACK-ERROR]
    return
  out.write "[ota] WRITE: ok\n"
  out.write #[ACK-OK]

// Stage the written slot as a trial and reset into it. Program/erase mode
// is kept ON (enabled in main) so the marker write rides the same enabled
// session as the slot writes — no separate program-mode toggle here.
stage out/io.Writer -> none:
  out.write "[ota] STAGE: marking inactive slot for trial and resetting\n"
  out.write #[ACK-OK]
  // stage-and-reset does not return — the device resets here.
  slot.stage-and-reset

// Confirm the running slot. Returns normally (no reset), so the receiver
// keeps serving commands afterwards.
validate out/io.Writer -> none:
  e := catch: slot.validate
  if e:
    out.write "[ota] VALIDATE: failed: $e\n"
    out.write #[ACK-ERROR]
    return
  out.write "[ota] VALIDATE: confirmed slot $(string.from-rune slot.active)\n"
  out.write #[ACK-OK]

// Reject the running slot and reset back to the previous slot.
invalidate out/io.Writer -> none:
  out.write "[ota] INVALIDATE: rejecting running slot and rolling back\n"
  out.write #[ACK-OK]
  // mark-invalid-and-reset does not return — the device resets here.
  slot.mark-invalid-and-reset
