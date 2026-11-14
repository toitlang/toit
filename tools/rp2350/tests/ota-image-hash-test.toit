// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.

import crypto.sha256 show Sha256
import expect show *
import host.file
import host.pipe
import io show LITTLE-ENDIAN

main args/List:
  if args.size != 2: throw "Usage: ota-image-hash-test PARSER-TEST IMAGE.bin"
  image := file.read-contents args[1]
  inspection := (pipe.backticks [args[0], "--inspect", args[1]]).trim
  values := (inspection.split " ").map: int.parse it
  expect (values.size >= 5 and values.size % 2 == 1)
  block-offset := values[0]
  block-size := values[1]
  digest-offset := values[2]
  digest := image[digest-offset..digest-offset + 32]
  ranges := []
  for at := 3; at < values.size; at += 2:
    ranges.add [values[at], values[at + 1]]
  terminal := image.copy block-offset (block-offset + block-size)
  expect-equals 0x9021_0142 (LITTLE-ENDIAN.uint32 terminal 4)
  terminal[7] &= 0x7f
  expect-equals digest (hash image ranges terminal)
  expect-not-equals digest (hash image ranges image[block-offset..block-offset + block-size])
  no-terminal-tbyb := image.copy
  no-terminal-tbyb[block-offset + 7] &= 0x7f
  expect-equals digest (hash no-terminal-tbyb ranges terminal)
  unpublished := image.copy
  4096.repeat: unpublished[it] = 0xff
  overlay-hash := Sha256
  ranges.do: |range|
    offset := range[0]
    size := range[1]
    if offset < 4096:
      overlay-size := min size (4096 - offset)
      overlay-hash.add image offset (offset + overlay-size)
      offset += overlay-size
      size -= overlay-size
    overlay-hash.add unpublished offset (offset + size)
  overlay-hash.add terminal
  expect-equals digest overlay-hash.get
  expect-not-equals digest (hash unpublished ranges terminal)
  root := -1
  for at := 0; at < 4096; at += 4:
    if (LITTLE-ENDIAN.uint32 image at) == 0xffff_ded3:
      root = at
      break
  expect (root >= 0)
  first-tbyb := image.copy
  first-tbyb[root + 7] &= 0x7f
  expect-not-equals digest (hash first-tbyb ranges terminal)
  corrupted := image.copy
  corrupted[root + 64] ^= 0x80
  expect-not-equals digest (hash corrupted ranges terminal)
  print "ota-image-hash-test: PASS picotool digest and TBYB masking"

hash image/ByteArray ranges/List terminal/ByteArray -> ByteArray:
  digest := Sha256
  ranges.do: |range| digest.add image range[0] (range[0] + range[1])
  digest.add terminal
  return digest.get
