// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.

import crypto.sha256 show Sha256 sha256
import encoding.hex
import expect show *
import host.file
import io show LITTLE-ENDIAN
import .host-test

CHUNK-SIZE ::= 4096
START ::= 0xffff_ded3
IMAGE-TYPE ::= 0x9021_0142

// All uploads are malformed. The confirmed active partition must survive each
// rejection; only the inactive slot is overwritten by these tests.
main argv/List:
  args := options argv ["port", "image"]
  good := file.read-contents args["image"]
  image-info := inspect-image good
  expect-equals image-info.stored-digest (image-info.digest good)
  body-offset := image-info.body-offset
  corrupt-body := good.copy
  corrupt-body[body-offset] ^= 1
  expect-not-equals image-info.stored-digest (image-info.digest corrupt-body)
  no-terminal-tbyb := good.copy
  no-terminal-tbyb[image-info.terminal + 7] &= 0x7f
  expect-equals image-info.stored-digest (image-info.digest no-terminal-tbyb)
  console := Console args["port"]
  try:
    baseline := console.info
    expect-equals 0 baseline[1]
    expect (good.size <= baseline[2])
    print "baseline: partition=$(baseline[0]) trial=0 slot=$(baseline[2]) image=$good.size"
    wrong-digest := sha256 good
    wrong-digest[0] ^= 1
    reject-upload console baseline "wrong-transport-sha" good wrong-digest "firmware: checksum mismatch"
    reject-upload console baseline "bad-rom-image-sha@$body-offset" corrupt-body (sha256 corrupt-body) "INVALID_ARGUMENT"
    reject-upload console baseline "terminal-tbyb-cleared" no-terminal-tbyb (sha256 no-terminal-tbyb) "INVALID_ARGUMENT"
    expect (good.size > 2 * CHUNK-SIZE)
    start-upload console good.size (sha256 good)
    send-chunks console good[..2 * CHUNK-SIZE]
    expect-error console "DEADLINE_EXCEEDED"
    verify-recovery console baseline
    print "truncated-timeout: PASS"
  finally:
    console.close
  print "ota-negative-test: PASS"

reject-upload console/Console baseline/List name/string image/ByteArray digest/ByteArray error/string:
  start-upload console image.size digest
  send-chunks console image
  expect-error console error
  verify-recovery console baseline
  print "$name: PASS error=$error"

start-upload console/Console size/int digest/ByteArray:
  console.command "TOIT-OTA WRITE $size $(hex.encode digest)"
  expect-equals "TOIT-OTA READY $CHUNK-SIZE" (console.protocol (now + 5000))

send-chunks console/Console image/ByteArray:
  deadline := now + 60_000
  offset := 0
  while offset < image.size:
    end := min image.size (offset + CHUNK-SIZE)
    with-timeout --ms=(max 1 (deadline - now)):
      console.port.out.write image[offset..end]
    offset = end
    expect-equals "TOIT-OTA ACK $offset" (console.protocol deadline)

expect-error console/Console expected/string:
  // A COMMITTED response fails this assertion and never triggers a reboot.
  expect-equals "TOIT-OTA ERROR $expected" (console.protocol (now + 30_000))

verify-recovery console/Console baseline/List:
  sleep --ms=50
  expect-structural-equals baseline console.info

word image/ByteArray at/int -> int:
  expect (at >= 0 and at + 4 <= image.size)
  return LITTLE-ENDIAN.uint32 image at

item-words header/int -> int:
  return (header >> 8) & (header & 0x80 != 0 ? 0xffff : 0xff)

block-end image/ByteArray start/int -> List:
  expect-equals START (word image start)
  at := start + 8
  while at + 12 <= image.size and at - start < 1024:
    header := word image at
    words := item-words header
    if header & 0xff == 0xff:
      expect-equals ((at - start - 4) / 4) words
      expect-equals 0xab12_3579 (word image (at + 8))
      return [at + 12, start + (LITTLE-ENDIAN.int32 image (at + 4))]
    expect (words > 0 and at + 4 * words <= image.size)
    at += 4 * words
  throw "Image-definition block has no LAST item"

class ImageInfo:
  terminal/int
  hash-size/int := 0
  digest-offset/int := 0
  stored-digest/ByteArray := #[]
  ranges/List := []

  constructor .terminal:

  digest image/ByteArray -> ByteArray:
    hash := Sha256
    ranges.do: |range| hash.add image range[0] (range[0] + range[1])
    definition := image.copy terminal (terminal + hash-size)
    // The ROM excludes the mutable terminal TBYB flag from its digest.
    definition[7] &= 0x7f
    hash.add definition
    return hash.get

  body-offset -> int:
    ranges.do: |range|
      if range[0] <= 8192 and 8192 < range[0] + range[1]: return 8192
    ranges.do: |range|
      candidate := max CHUNK-SIZE range[0]
      if candidate < range[0] + range[1]: return candidate
    throw "Image has no hashed body above the publication sector"

inspect-image image/ByteArray -> ImageInfo:
  expect (image.size >= CHUNK-SIZE and image.size % 4 == 0)
  roots := []
  for at := 0; at < CHUNK-SIZE; at += 4:
    if (word image at) == START: roots.add at
  expect-equals 1 roots.size
  root := roots[0]
  expect-equals IMAGE-TYPE (word image (root + 4))
  terminal := (block-end image root)[1]
  expect (terminal >= CHUNK-SIZE and terminal < image.size)
  expect-equals START (word image terminal)
  expect-equals IMAGE-TYPE (word image (terminal + 4))
  result := ImageInfo terminal
  at := terminal + 8
  closed := false
  while at + 12 <= image.size:
    header := word image at
    tag := header & 0xff
    words := item-words header
    if tag == 0xff:
      expect-structural-equals [image.size, root] (block-end image terminal)
      closed = true
      break
    expect (words > 0 and at + words * 4 <= image.size)
    if tag == 0x06:
      count := header >> 24
      expect (count > 0 and words == 1 + 3 * count and result.ranges.is-empty)
      count.repeat: |index|
        entry := at + 4 + index * 12
        offset := at + (LITTLE-ENDIAN.int32 image entry)
        size := word image (entry + 8)
        expect (offset >= 0 and size > 0 and offset + size <= terminal)
        result.ranges.add [offset, size]
    else if tag == 0x47:
      expect-equals 0x0100_0247 header
      expect-equals 0 result.hash-size
      result.hash-size = (word image (at + 4)) * 4
    else if tag == 0x4b:
      expect-equals 0x94b header
      expect-equals 0 result.digest-offset
      result.digest-offset = at + 4
    at += words * 4
  expect closed
  expect (result.ranges.size > 0 and result.hash-size >= 8)
  expect-equals result.digest-offset (terminal + result.hash-size + 4)
  expect (result.digest-offset + 32 <= image.size)
  result.stored-digest = image[result.digest-offset..result.digest-offset + 32]
  return result
