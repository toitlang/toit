// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import io

import ...gdb.src.gdb as gdb
import ..checkpoints

main:
  capabilities := "PacketSize=1000;QStartNoAckMode+"
  responses := #[43] + (gdb.encode-packet capabilities.to-byte-array)
  responses += #[43] + (gdb.encode-packet "OK".to-byte-array)
  responses += gdb.encode-packet "OK".to-byte-array
  responses += gdb.encode-packet "OK".to-byte-array
  responses += gdb.encode-packet "T05thread:p1.1;".to-byte-array
  responses += gdb.encode-packet "OK".to-byte-array
  responses += gdb.encode-packet "OK".to-byte-array
  responses += gdb.encode-packet "T05thread:p1.1;".to-byte-array
  responses += gdb.encode-packet "03000000".to-byte-array
  responses += gdb.encode-packet "78563412".to-byte-array
  writer := io.Buffer
  client := gdb.Client (io.Reader responses) writer
  client.initialize
  evidence := run-to-checkpoint client layout "scavenge-after-forwarding"
  expect-equals "scavenge-after-forwarding" evidence["name"]
  expect-equals 3 evidence["id"]
  expect-equals "0x12345678" evidence["context"]
  expect-equals 5 evidence["arm-stop"]["signal"]
  expect-equals "p1.1" evidence["hit-stop"]["thread-id"]

layout ::= {
  "format": LAYOUT-FORMAT,
  "format-version": LAYOUT-VERSION,
  "pointer-size": 4,
  "byte-order": "little",
  "checkpoints": [
    {"name": "scavenge-after-forwarding", "id": 3},
  ],
  "symbols": {
    ARM-SYMBOL: "0x4000",
    HIT-SYMBOL: "0x5000",
    REQUESTED-SYMBOL: "0x6000",
    CURRENT-SYMBOL: "0x7000",
    CONTEXT-SYMBOL: "0x8000",
  },
}
