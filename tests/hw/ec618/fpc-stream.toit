// Copyright (C) 2026 Toit contributors.

import uart

pattern size/int seed/int -> ByteArray:
  return ByteArray size: (it * 31 + seed) & 0xff

send-stream port/uart.Port size/int seed/int:
  bytes := pattern 1024 seed
  offset := 0
  with-timeout --ms=20_000:
    while offset < size:
      length := min 1024 (size - offset)
      port.out.write bytes[..length]
      offset += length
      yield
    port.out.flush

receive-stream port/uart.Port size/int seed/int:
  // Compare blocks natively, as in tests/hw/ec618/uart-stream.toit. Interpreted
  // per-byte checks cannot keep up; retaining the whole stream costs too much
  // memory during duplex transfers. An extra period covers arbitrary offsets.
  expected := pattern (1024 + 256) seed
  count := 0
  error := catch:
    with-timeout --ms=20_000:
      while count < size:
        bytes := port.in.read
        if not bytes: throw "UART closed early"
        if count + bytes.size > size: throw "UART received too many bytes"
        checked := 0
        while checked < bytes.size:
          length := min 1024 (bytes.size - checked)
          phase := (count + checked) & 0xff
          if bytes[checked .. checked + length] != expected[phase .. phase + length]:
            length.repeat: |index|
              if bytes[checked + index] != expected[phase + index]:
                throw "UART data mismatch at $(count + checked + index): expected=$(expected[phase + index]) got=$(bytes[checked + index])"
          checked += length
        count += bytes.size
  if error: throw "$error (received=$count/$size errors=$port.errors)"
  if count != size: throw "UART byte count mismatch"
