// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import io
import uart

main:
  port := uart.Port.console

  io.stdout.write "IO-READY\n"
  data := io.stdin.read
  io.stdout.write "IO:"
  if data: io.stdout.write data

  io.stdout.write "UART-READY\n"
  data = port.in.read
  io.stdout.write "UART:"
  if data: io.stdout.write data
