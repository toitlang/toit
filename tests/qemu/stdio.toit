// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import io

main:
  io.stdout.write "STDIO-READY\n"
  data := io.stdin.read
  io.stdout.write "STDOUT:"
  if data: io.stdout.write data
  io.stderr.write "STDERR:"
  if data: io.stderr.write data
