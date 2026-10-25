// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.

import io show LITTLE-ENDIAN
import uuid show Uuid

PAGE-SIZE ::= 4096
LAYOUT-MAGIC ::= "TOITZPH1"
LAYOUT-SIZE ::= 44

/** Validates an nRF5340 network-core controller linked at 0x01000000. */
validate-nrf5340-controller binary/ByteArray -> none:
  if not 8 <= binary.size <= 0x40000:
    throw "nRF5340 controller must fit in 256 KiB"
  stack := LITTLE-ENDIAN.uint32 binary 0
  entry := LITTLE-ENDIAN.uint32 binary 4
  if not 0x21000000 < stack <= 0x21010000 or stack % 8 != 0 or
      entry & 1 == 0 or not 0x01000008 <= (entry & ~1) < 0x01000000 + binary.size:
    throw "Invalid nRF5340 controller vector table"

interface Container:
  relocate --relocation-base/int --attach-assets/bool --system-uuid/Uuid -> ByteArray

/** Validates a relocatable 32-bit image and returns whether it includes assets. */
validate-relocatable encoded/ByteArray sdk-uuid/Uuid -> bool:
  if encoded.is-empty or encoded.size % 132 != 0:
    throw "Expected a 32-bit Zephyr relocatable image"
  bits := ByteArray encoded.size / 132 * 128
  (encoded.size / 132).repeat: |index|
    bits.replace (index * 128) encoded[index * 132 + 4..(index + 1) * 132]
  if bits.size < PAGE-SIZE or bits.size % PAGE-SIZE != 0:
    throw "Zephyr image must be page aligned"
  program-size := (LITTLE-ENDIAN.uint16 bits 30) * PAGE-SIZE
  inline-assets := bits.size > program-size
  if inline-assets: bits[24] |= 0x80
  validate-program bits sdk-uuid
  (encoded.size / 132).repeat: |index|
    mask := LITTLE-ENDIAN.uint32 encoded (index * 132)
    32.repeat: |bit|
      if (mask & (1 << bit)) == 0: continue.repeat
      offset := index * 128 + bit * 4
      if offset < 48 or offset >= program-size or
          (LITTLE-ENDIAN.uint32 bits offset) > program-size:
        throw "Zephyr relocation points outside its program"
  return inline-assets

/**
Describes the replaceable, final extension in a 32-bit Zephyr firmware binary.

The linker emits this descriptor before the extension, including the native
  SDK identity and the code partition boundary. Changing container sizes must
  never move native code or extend into persistent storage.
*/
class Layout:
  load-address/int
  extension-address/int
  limit/int
  sdk-uuid/Uuid

  constructor bits/ByteArray:
    found := -1
    scan-limit := bits.size
    for at := 0; at + LAYOUT-SIZE <= scan-limit; at += 4:
      if bits[at..at + 8] != LAYOUT-MAGIC.to-byte-array: continue
      if (LITTLE-ENDIAN.uint32 bits (at + 40)) != 0x315a5445: continue
      candidate-offset := (LITTLE-ENDIAN.uint32 bits (at + 16)) -
          (LITTLE-ENDIAN.uint32 bits (at + 12))
      if candidate-offset < at + LAYOUT-SIZE or candidate-offset >= bits.size: continue
      if found != -1: throw "Ambiguous Zephyr layout descriptor"
      found = at
      // Container assets may contain arbitrary bytes, including the marker or
      // a copy of this descriptor. Only native bytes can describe the layout.
      scan-limit = candidate-offset
    if found == -1: throw "Missing Zephyr layout descriptor; rebuild the native firmware"
    if (LITTLE-ENDIAN.uint32 bits (found + 8)) != 1 or
        (LITTLE-ENDIAN.uint32 bits (found + 40)) != 0x315a5445:
      throw "Unsupported Zephyr layout descriptor"
    load-address = LITTLE-ENDIAN.uint32 bits (found + 12)
    extension-address = LITTLE-ENDIAN.uint32 bits (found + 16)
    limit = LITTLE-ENDIAN.uint32 bits (found + 20)
    sdk-uuid = Uuid bits[found + 24..found + 40]
    if load-address % PAGE-SIZE != 0 or
        extension-address % PAGE-SIZE != 0 or
        limit % PAGE-SIZE != 0 or
        not load-address <= extension-address < limit or
        extension-offset < found + LAYOUT-SIZE or
        bits.size > limit - load-address or
        extension-offset + PAGE-SIZE > bits.size:
      throw "Invalid Zephyr code partition or extension bounds"
    validate-extension_ bits

  extension-offset -> int:
    return extension-address - load-address

  validate-extension_ bits/ByteArray -> none:
    at := extension-offset
    marker := LITTLE-ENDIAN.uint32 bits at
    used := LITTLE-ENDIAN.uint32 bits (at + 4)
    free := LITTLE-ENDIAN.uint32 bits (at + 8)
    count := LITTLE-ENDIAN.uint32 bits (at + 12)
    checksum := LITTLE-ENDIAN.uint32 bits (at + 16)
    if marker != 0x98dfc301 or (marker ^ used ^ free ^ count ^ checksum) != 0xb3147ee9:
      throw "Invalid Zephyr extension header"
    if free != 0 or used % PAGE-SIZE != 0 or at + used != bits.size or
        not 1 <= count <= (PAGE-SIZE - 20) / 8:
      throw "Zephyr extension must be the complete final section"
    next := at + PAGE-SIZE
    count.repeat: |index|
      address := LITTLE-ENDIAN.uint32 bits (at + 20 + index * 8)
      size := LITTLE-ENDIAN.uint32 bits (at + 24 + index * 8)
      if address != load-address + next or size == 0 or size % PAGE-SIZE != 0 or next + size > bits.size:
        throw "Invalid Zephyr embedded image bounds"
      validate-program bits[next..next + size] sdk-uuid
      next += size
    if next != bits.size: throw "Unexpected bytes after Zephyr containers"

/** Validates the bounds and identity of an embedded image, including assets. */
validate-program bits/ByteArray sdk-uuid/Uuid -> none:
  if bits.size < 48 or (LITTLE-ENDIAN.uint32 bits 0) != 0xdeadface or
      (LITTLE-ENDIAN.uint32 bits 4) != 0 or bits[29] != 0 or
      bits[32..48] != sdk-uuid.to-byte-array:
    throw "Invalid Zephyr program header or SDK identity"
  size := (LITTLE-ENDIAN.uint16 bits 30) * PAGE-SIZE
  if size == 0 or size > bits.size: throw "Invalid Zephyr program size"
  if (bits[24] & 0x80) != 0:
    if size + 4 > bits.size: throw "Missing Zephyr assets length"
    size += round-up (4 + (LITTLE-ENDIAN.uint32 bits size)) PAGE-SIZE
  if size != bits.size: throw "Invalid Zephyr image or assets size"

/** Replaces the bundled containers without changing any native firmware bytes. */
build-image binary/ByteArray containers/List -> ByteArray:
  layout := Layout binary
  if not 1 <= containers.size <= (PAGE-SIZE - 20) / 8:
    throw "Zephyr requires a system container and at most 509 containers"
  extension := ByteArray PAGE-SIZE
  ids := {}
  index := 0
  containers.do: |container/Container|
    address := layout.extension-address + extension.size
    bits := container.relocate
        --relocation-base=address
        --attach-assets
        --system-uuid=layout.sdk-uuid
    padded-size := round-up bits.size PAGE-SIZE
    if address + padded-size > layout.limit: throw "Zephyr containers exceed the code partition"
    bits += ByteArray padded-size - bits.size
    validate-program bits layout.sdk-uuid
    id := Uuid bits[8..24]
    if ids.contains id: throw "Duplicate Zephyr container ID: $id"
    ids.add id
    LITTLE-ENDIAN.put-uint32 extension (20 + index * 8) address
    LITTLE-ENDIAN.put-uint32 extension (24 + index * 8) bits.size
    extension += bits
    index++
  LITTLE-ENDIAN.put-uint32 extension 0 0x98dfc301
  LITTLE-ENDIAN.put-uint32 extension 4 extension.size
  LITTLE-ENDIAN.put-uint32 extension 12 containers.size
  LITTLE-ENDIAN.put-uint32 extension 16 (0x98dfc301 ^ extension.size ^ containers.size ^ 0xb3147ee9)
  result := binary[..layout.extension-offset] + extension
  // Validate the final table, not just the individual input images.
  Layout result
  return result
