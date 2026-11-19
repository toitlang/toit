// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import encoding.tison
import expect show *

// TISON input is untrusted. Decoding must not create strings that aren't
// valid UTF-8: the VM's string primitives rely on it (they read as many
// continuation bytes as a first byte announces).

main:
  encoded := tison.encode "ab\u{1F600}"
  expect-equals "ab\u{1F600}" (tison.decode encoded)
  emoji-start := encoded.size - 4

  // A first byte that announces more bytes than there are.
  [0xff, 0xf0, 0xe0, 0xc2].do: | first |
    bytes := encoded.copy
    bytes[bytes.size - 1] = first
    expect-throw "WRONG_OBJECT_TYPE": tison.decode bytes

  // A continuation byte without a first byte.
  bytes := encoded.copy
  bytes[emoji-start] = 0x80
  expect-throw "WRONG_OBJECT_TYPE": tison.decode bytes

  // An overlong encoding and a surrogate.
  [[0xc0, 0x80], [0xed, 0xa0, 0x80]].do: | sequence |
    invalid := encoded.copy
    sequence.size.repeat: invalid[emoji-start + it] = sequence[it]
    if sequence.size < 4: invalid[emoji-start + sequence.size..].fill 'x'
    expect-throw "WRONG_OBJECT_TYPE": tison.decode invalid

  // Map keys are strings too.
  map-bytes := tison.encode {"k\u{1F600}": 1}
  index := -1
  map-bytes.size.repeat: if map-bytes[it] == 0xf0: index = it
  map-bytes[index] = 0xff
  expect-throw "WRONG_OBJECT_TYPE": tison.decode map-bytes
