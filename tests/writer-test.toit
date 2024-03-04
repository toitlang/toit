// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import io
import writer show Writer
import monitor

class WriterThatOnlyWritesOneByte:
  bytes := []
  reset:
    bytes = []
  write data/io.Data:
    if data.byte-size == 0: return 0
    bytes.add (data.byte-at 0)
    return 1

main:
  underlying := WriterThatOnlyWritesOneByte
  writer := Writer underlying
  writer.write "foo"
  expect-equals ['f', 'o', 'o'] underlying.bytes

  underlying.reset
  writer.write "Søen så"
  expect-equals ['S', 0xc3, 0xb8, 'e', 'n', ' ', 's', 0xc3, 0xa5] underlying.bytes

  underlying.reset
  writer.write "Only €100"
  expect-equals ['O', 'n', 'l', 'y', ' ', 0xe2, 0x82, 0xac, '1', '0', '0'] underlying.bytes
