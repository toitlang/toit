// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
import crypto.sha256 as crypto
import io show LITTLE-ENDIAN
import uuid show Uuid
import .container show Container

WORD-SIZE ::= 4
XIP-BASE_ ::= 0x1000_0000
SLOT-SIZE_ ::= 4 * 1024 * 1024
START_ ::= 0xffff_ded3
END_ ::= 0xab12_3579
IMAGE-TYPE_ ::= 0x9021_0142

invalid_ -> none:
  throw "Invalid RP2350 hashed trial image"

word_ bytes/ByteArray at/int -> int:
  if at < 0 or at + 4 > bytes.size or at & 3 != 0: invalid_
  return LITTLE-ENDIAN.uint32 bytes at

put_ bytes/ByteArray at/int value/int -> none:
  LITTLE-ENDIAN.put-uint32 bytes at (value & 0xffff_ffff)

class Range_:
  offset/int
  runtime/int
  size/int
  constructor .offset .runtime .size:

class Block_:
  start/int
  end/int := 0
  next/int := 0
  link-offset/int := 0
  version/int? := null
  ranges/List? := null
  hash-size/int := 0
  digest-offset/int := 0
  constructor .start:

parse-block_ bytes/ByteArray start/int --terminal/bool -> Block_:
  if (word_ bytes start) != START_ or (word_ bytes (start + 4)) != IMAGE-TYPE_: invalid_
  result := Block_ start
  at := start + 8
  while at + 12 <= bytes.size and at - start < 372:
    header := word_ bytes at
    tag := header & 0xff
    words := (header >> 8) & ((tag & 0x80 != 0) ? 0xffff : 0xff)
    if tag == 0xff:
      if words != (at - start - 4) / 4 or header >> 24 != 0: invalid_
      if (word_ bytes (at + 8)) != END_: invalid_
      result.end = at + 12
      result.link-offset = at + 4
      result.next = start + (LITTLE-ENDIAN.int32 bytes (at + 4))
      if result.next < 0 or result.next >= bytes.size or result.next & 3 != 0: invalid_
      if result.version == null: invalid_
      if terminal:
        if not result.ranges or result.hash-size == 0 or result.digest-offset == 0: invalid_
      else if result.ranges or result.hash-size != 0 or result.digest-offset != 0:
        invalid_
      return result
    if words == 0 or at + words * 4 > bytes.size or at - start + words * 4 > 372:
      invalid_
    if tag == 0x48:
      if header != 0x248 or result.version != null or result.hash-size != 0: invalid_
      result.version = word_ bytes (at + 4)
    else if tag == 0x06:
      count := header >> 24
      if not terminal or result.ranges or result.hash-size != 0 or not (1 <= count <= 16): invalid_
      if words != 1 + 3 * count: invalid_
      result.ranges = []
      covered := 0
      count.repeat: | index/int |
        entry := at + 4 + index * 12
        relative := LITTLE-ENDIAN.int32 bytes entry
        offset := at + relative
        runtime := word_ bytes (entry + 4)
        size := word_ bytes (entry + 8)
        if (offset | runtime | size) & 3 != 0: invalid_
        if relative == 0 or offset < covered or offset > start or size == 0 or size > start - offset:
          invalid_
        for padding := covered; padding < offset; padding += 4:
          if (word_ bytes padding) != 0: invalid_
        xip := runtime == XIP-BASE_ + offset
        sram := 0x2000_0000 <= runtime < 0x2008_2000 and size <= 0x2008_2000 - runtime
        if not (xip or sram): invalid_
        result.ranges.add (Range_ offset runtime size)
        covered = offset + size
      if covered != start: invalid_
    else if tag == 0x47:
      if not terminal or not result.ranges or result.hash-size != 0 or header != 0x0100_0247: invalid_
      result.hash-size = (word_ bytes (at + 4)) * 4
      if result.hash-size != at + 8 - start: invalid_
    else if tag == 0x4b:
      if result.hash-size == 0 or result.digest-offset != 0 or header != 0x94b: invalid_
      if at != start + result.hash-size: invalid_
      result.digest-offset = at + 4
    else:
      invalid_
    at += words * 4
  invalid_
  unreachable

digest_ bytes/ByteArray block/Block_ -> ByteArray:
  hash := crypto.Sha256
  block.ranges.do: | range/Range_ |
    hash.add bytes[range.offset..range.offset + range.size]
  definition := bytes.copy block.start (block.start + block.hash-size)
  definition[7] &= 0x7f
  hash.add definition
  return hash.get

class Image_:
  bytes/ByteArray
  root/Block_
  terminal/Block_

  constructor .bytes:
    if not (4096 <= bytes.size <= SLOT-SIZE_) or bytes.size & 3 != 0: invalid_
    found/Block_? := null
    for offset := 0; offset < 4096; offset += 4:
      if (word_ bytes offset) != START_: continue
      if found: invalid_
      found = parse-block_ bytes offset --terminal=false
    if not found or found.end > 4096 or found.next < 4096: invalid_
    root = found
    terminal = parse-block_ bytes root.next --terminal
    if terminal.end != bytes.size or terminal.next != root.start or terminal.version != root.version:
      invalid_
    expected := bytes[terminal.digest-offset..terminal.digest-offset + 32]
    if (digest_ bytes terminal) != expected: throw "RP2350 image hash mismatch"

  details-offset -> int:
    found/int? := null
    for offset := 0; offset + 28 <= terminal.start; offset += 4:
      if (word_ bytes offset) != 0x7017_da7a: continue
      if (word_ bytes (offset + 24)) != 0x00c0_9f19: continue
      if found != null: throw "Ambiguous RP2350 image-details marker"
      // The descriptor must remain in XIP, not in the SRAM initializer.
      in-xip := terminal.ranges.any: | range/Range_ |
        range.runtime == XIP-BASE_ + range.offset and
            range.offset <= offset and offset + 28 <= range.offset + range.size
      if not in-xip: invalid_
      found = offset + 4
    if found == null: throw "Missing RP2350 image-details marker"
    return found

validate-envelope-base bytes/ByteArray -> none:
  image := Image_ bytes
  image.details-offset

build-extension_ containers/List system-uuid/Uuid config/ByteArray base/int -> ByteArray:
  if containers.is-empty: throw "RP2350 firmware requires a system container"
  result := ByteArray (round-up (20 + 8 * containers.size) 4096)
  containers.size.repeat: | index/int |
    container/Container := containers[index]
    offset := result.size
    bytes := container.relocate
        --relocation-base=base + offset
        --attach-assets
        --system-uuid=system-uuid
    put_ result (20 + 8 * index) (base + offset)
    put_ result (24 + 8 * index) bytes.size
    result += bytes
    result += ByteArray ((round-up result.size 4096) - result.size)
    if result.size > SLOT-SIZE_: throw "RP2350 containers exceed firmware slot"
  used := result.size
  free := round-up (4 + config.size) 4
  result += ByteArray free
  put_ result used config.size
  result.replace (used + 4) config
  put_ result 0 0x98df_c301
  put_ result 4 used
  put_ result 8 free
  put_ result 12 containers.size
  put_ result 16 (0xb314_7ee9 ^ 0x98df_c301 ^ used ^ free ^ containers.size)
  return result

terminal_ ranges/List version/int start/int root/int -> ByteArray:
  if ranges.size > 16: throw "Too many RP2350 image ranges"
  words := [START_, IMAGE-TYPE_, 0x248, version]
  map-offset := start + words.size * 4
  words.add ((ranges.size << 24) | ((1 + ranges.size * 3) << 8) | 6)
  ranges.do: | range/Range_ |
    words.add range.offset - map-offset
    words.add range.runtime
    words.add range.size
  words.add 0x0100_0247
  words.add (words.size + 1)
  words.add 0x94b
  8.repeat: words.add 0
  words.add (((words.size - 1) << 8) | 0xff)
  words.add root - start
  words.add END_
  result := ByteArray words.size * 4
  words.size.repeat: | index/int | put_ result (index * 4) words[index]
  return result

/** Builds a complete hashed image without moving the VM's linked segments. */
build-image -> ByteArray
    --binary-input/ByteArray
    --containers/List
    --system-uuid/Uuid
    --config-encoded/ByteArray:
  original := Image_ binary-input
  details := original.details-offset
  extension-offset := round-up original.terminal.start 4096
  extension := build-extension_ containers system-uuid config-encoded (XIP-BASE_ + extension-offset)
  result := binary-input.copy 0 original.terminal.start
  result += ByteArray (extension-offset - result.size)
  result += extension
  ranges := original.terminal.ranges.copy
  ranges.add (Range_ extension-offset (XIP-BASE_ + extension-offset) extension.size)
  terminal-start := result.size
  result += terminal_ ranges original.root.version terminal-start original.root.start
  if result.size > SLOT-SIZE_: throw "RP2350 image exceeds the 4 MiB firmware slot"
  put_ result original.root.link-offset (terminal-start - original.root.start)
  put_ result details (XIP-BASE_ + extension-offset)
  result.replace (details + 4) system-uuid.to-byte-array
  block := parse-block_ result terminal-start --terminal
  result.replace block.digest-offset (digest_ result block)
  // Reparse and independently check all final bounds, links, ranges and hash.
  Image_ result
  return result

/** Returns the bought-image form used for blank-board recovery.

The ROM's explicit-buy operation clears the TBYB bit in the terminal image
definition only. The ROM hash masks this bit, so the stored digest is unchanged.
OTA images retain the bit and continue through try-before-you-buy validation.
*/
confirmed-recovery-image bytes/ByteArray -> ByteArray:
  image := Image_ bytes
  result := bytes.copy
  flag-offset := image.terminal.start + 7
  if result[flag-offset] & 0x80 == 0: invalid_
  result[flag-offset] &= 0x7f
  expected := result[image.terminal.digest-offset..image.terminal.digest-offset + 32]
  if (digest_ result image.terminal) != expected:
    throw "RP2350 recovery image hash mismatch"
  return result

parts bytes/ByteArray -> List:
  image := Image_ bytes
  extension := (word_ bytes image.details-offset) - XIP-BASE_
  if extension < 0:
    return [{"type": "binary", "from": 0, "to": bytes.size}]
  if extension < 4096 or extension + 20 > image.terminal.start: invalid_
  used := word_ bytes (extension + 4)
  free := word_ bytes (extension + 8)
  if extension + used + free > image.terminal.start: invalid_
  return [
    {"type": "binary", "from": 0, "to": extension},
    {"type": "images", "from": extension, "to": extension + used},
    {"type": "config", "from": extension + used, "to": extension + used + free},
    {"type": "checksum", "from": image.terminal.start, "to": bytes.size},
  ]
