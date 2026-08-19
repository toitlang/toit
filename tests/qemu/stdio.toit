// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import io

main:
  // Initialize stdin before announcing readiness.
  // The ESP32 UART driver flushes pending input when installed.
  input := io.stdin
  io.stdout.write "STDIO-READY\n"
  data := input.read-line --keep-newline
  io.stdout.write "STDOUT:"
  if data: io.stdout.write data
  io.stderr.write "STDERR:"
  if data: io.stderr.write data
