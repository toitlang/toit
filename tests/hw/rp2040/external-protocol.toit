// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
import expect show expect-equals
import uart

pattern size/int seed/int -> ByteArray:
  return ByteArray size: (it * 31 + seed) & 0xff

send port/uart.Port line/string:
  port.out.write "$line\n"
  port.out.flush

receive port/uart.Port -> string:
  return with-timeout --ms=30_000: port.in.read-string-up-to '\n'

request port/uart.Port line/string:
  send port line
  expect-equals "OK" (receive port)
