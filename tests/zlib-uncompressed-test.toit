// Copyright (C) 2018 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import bytes
import expect show *
import zlib show *
import host.pipe
import host.file
import monitor show *

main:
  encoder := UncompressedZlibEncoder --no-split-writes

  zs := "z" * 0x2020
  bytes-written := encoder.out.try-write zs.to-byte-array
  // Wrote all of it.
  expect-equals zs.size bytes-written
  // Read encoded output, strip 2-byte zlib and 5-byte block header.
  str := encoder.in.read[7..].to-string
  expect-equals zs.size str.size
  expect-equals zs str
  encoder.out.close
  rest := encoder.in.read
  // Expect a 5-byte empty literal section (in order to have a block where the
  // last-block bit is set), followed by the 4 byte checksum.
  expect-equals 9 rest.size
