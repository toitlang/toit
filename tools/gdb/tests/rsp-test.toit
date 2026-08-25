// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import io

import gdb.gdb show *

main:
  expect-equals "\$g#67" (encode-packet "g".to-byte-array).to-string
  expect-equals "0000" (decode-payload #[48, 42, 32]).to-string
  expect-equals "A#B" (decode-payload #[65, 125, 3, 66]).to-string
  expect-throw "TRUNCATED_GDB_ESCAPE": decode-payload #[125]

  capabilities := "PacketSize=1000;QStartNoAckMode+"
  responses := #[43] + (encode-packet capabilities.to-byte-array)
  responses += #[43] + (encode-packet "OK".to-byte-array)
  responses += encode-packet "01020304".to-byte-array
  responses += encode-packet "OK".to-byte-array
  responses += encode-packet "OK".to-byte-array
  responses += encode-packet "T05thread:p1.1;".to-byte-array
  reader := io.Reader responses
  writer := io.Buffer
  client := Client reader writer
  client.initialize
  expect (client.capabilities.contains "PacketSize=1000")
  request := "qSupported:multiprocess+;qXfer:features:read+;qXfer:threads:read+"
  expected := encode-packet request.to-byte-array
  expected += #[43] + (encode-packet "QStartNoAckMode".to-byte-array) + #[43]
  expect-equals #[1, 2, 3, 4] (client.read-memory 0x1000 4)
  client.write-memory 0x2000 #[0xde, 0xad, 0xbe, 0xef]
  client.insert-software-breakpoint 0x4000
  stop := client.continue-execution
  expect-equals 5 stop.signal
  expect-equals "p1.1" stop.thread-id
  expected += encode-packet "m1000,4".to-byte-array
  expected += encode-packet "M2000,4:deadbeef".to-byte-array
  expected += encode-packet "Z0,4000,1".to-byte-array
  expected += encode-packet "c".to-byte-array
  expect-equals expected writer.bytes
