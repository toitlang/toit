// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import io

main:
  data := io.stdin.read-all
  io.stdout.write "stdout:"
  if data: io.stdout.write data
  io.stderr.write "stderr:"
  if data: io.stderr.write data
