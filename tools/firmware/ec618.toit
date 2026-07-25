// Copyright (C) 2026 Toit contributors.
//
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Lesser General Public
// License as published by the Free Software Foundation; version
// 2.1 only.
//
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Lesser General Public License for more details.
//
// The license can be found in the file `LICENSE` in the top level
// directory of this repository.

import crypto.crc show Crc
import crypto.sha256 as crypto
import io show LITTLE-ENDIAN
import uuid show Uuid

import ..ec618.slot-reloc show SlotRelocTable TO-SLOT TO-CANONICAL
import .image-details as image-details

WORD-SIZE ::= 4

XIP-BASE_       ::= 0x00800000
AP-LOAD-OFFSET_ ::= 0x00024000
FLASH-SECTOR-SIZE_ ::= 4096

/**
Container operations needed by the EC618 image builder.
*/
interface Container:
  relocatable -> ByteArray
  relocated-size -> int
  relocate --relocation-base/int --attach-assets/bool --system-uuid/Uuid -> ByteArray

pad_ bits/ByteArray alignment/int -> ByteArray:
  padded-size := round-up bits.size alignment
  return bits + (ByteArray padded-size - bits.size)

/**
Returns slot A's XIP address from the anchor record in the AP $image.
*/
slot-a-xip_ image/ByteArray -> int:
  for off := 0; off + 32 <= image.size; off += 0x1000:
    if (LITTLE-ENDIAN.uint16 image off) != 0x4154: continue
    if image[off + 2] != 2: continue
    count := image[off + 10]
    record-size := 16 + count * 32 + 16
    if count == 0 or off + record-size > image.size: continue
    crc := Crc.little-endian 32
        --polynomial=0xEDB88320
        --initial-state=0xffff_ffff
        --xor-result=0xffff_ffff
    crc.add image[off .. off + record-size - 16]
    if crc.get-as-int != (LITTLE-ENDIAN.uint32 image (off + record-size - 16)): continue
    count.repeat: | i/int |
      entry := off + 16 + i * 32
      if image[entry + 24] == 5:
        return XIP-BASE_ + (LITTLE-ENDIAN.uint32 image (entry + 16))
  throw "no anchor record in the AP image — it must be provisioned (tools/ec618/gen-anchor.toit)"

/**
Builds the canonical table-first OTA image from a slot-A AP $image.
*/
canonical-firmware image/ByteArray table/SlotRelocTable -> ByteArray:
  load-xip := XIP-BASE_ + AP-LOAD-OFFSET_
  slot-a-xip := slot-a-xip_ image
  slot-a-file := slot-a-xip - load-xip
  size-pos := slot-a-file + table.slot-size - 4
  table-length := LITTLE-ENDIAN.uint32 image size-pos
  table-bytes := image.copy (size-pos - table-length) size-pos
  merged := SlotRelocTable.parse table-bytes
  populated := merged.body-size
  body := image.copy slot-a-file (slot-a-file + populated)
  merged.apply body
      --base=0
      --delta=(slot-a-xip - merged.link-base)
      --direction=TO-CANONICAL
  data := image.copy
      (slot-a-file + populated)
      (slot-a-file + populated + merged.data-size)
  size-word := ByteArray 4
  LITTLE-ENDIAN.put-uint32 size-word 0 table-length
  return size-word + table-bytes + body + data

/**
Builds an EC618 AP image containing the supplied $containers and configuration.
*/
build-image -> ByteArray
    --binary-input/ByteArray
    --containers/List
    --system-uuid/Uuid
    --config-encoded/ByteArray
    --reloc-table/SlotRelocTable?
    --vm-data/ByteArray?:
  if reloc-table:
    return build-in-slot_
        --binary-input=binary-input
        --containers=containers
        --system-uuid=system-uuid
        --config-encoded=config-encoded
        --reloc-table=reloc-table
        --vm-data=vm-data

  padded-binary := pad_ binary-input FLASH-SECTOR-SIZE_
  extension-xip-addr := XIP-BASE_ + AP-LOAD-OFFSET_ + padded-binary.size
  extension := build-extension_
      --containers=containers
      --system-uuid=system-uuid
      --config-encoded=config-encoded
      --extension-xip-addr=extension-xip-addr
  result := padded-binary.copy
  patch-details_ result
      --extension-xip-addr=extension-xip-addr
      --system-uuid=system-uuid
  result += extension.bytes
  result += crypto.sha256 result
  return result

build-in-slot_ -> ByteArray
    --binary-input/ByteArray
    --containers/List
    --system-uuid/Uuid
    --config-encoded/ByteArray
    --reloc-table/SlotRelocTable
    --vm-data/ByteArray?:
  load-xip := XIP-BASE_ + AP-LOAD-OFFSET_
  link-base := reloc-table.link-base
  slot-size := reloc-table.slot-size
  vm-body := reloc-table.body-size
  slot-a-xip := slot-a-xip_ binary-input
  slot-file := slot-a-xip - load-xip

  if vm-body % 4 != 0:
    throw "EC618 VM body size 0x$(%x vm-body) is not word-aligned"

  extension-xip-addr := link-base + vm-body
  extension := build-extension_
      --containers=containers
      --system-uuid=system-uuid
      --config-encoded=config-encoded
      --extension-xip-addr=extension-xip-addr
  verify-extension-relocation_ extension
      --containers=containers
      --system-uuid=system-uuid
      --config-encoded=config-encoded
      --extension-xip-addr=extension-xip-addr
      --displacement=slot-size
  verify-extension-relocation_ extension
      --containers=containers
      --system-uuid=system-uuid
      --config-encoded=config-encoded
      --extension-xip-addr=extension-xip-addr
      --displacement=0x1000

  result := binary-input.copy
  details-offset := image-details.find-offset result --word-size=WORD-SIZE
  if details-offset < slot-file or details-offset >= slot-file + vm-body:
    throw "EC618 DromData at file 0x$(%x details-offset) is outside the VM slot"
  patch-details_ result
      --extension-xip-addr=extension-xip-addr
      --system-uuid=system-uuid

  extra-abs32 := [details-offset - slot-file]
  extension.pointer-offsets.do:
    extra-abs32.add (vm-body + it)
  populated := vm-body + extension.bytes.size
  merged := reloc-table.merge-extension
      --extra-abs32=extra-abs32
      --populated-size=populated

  data-size := merged.data-size
  if data-size > 0 and (vm-data == null or vm-data.size != data-size):
    carried := vm-data == null ? "none" : "0x$(%x vm-data.size)"
    throw "EC618 reloc table wants 0x$(%x data-size) bytes of VM .data but the envelope carries $carried (\$ec618-data.bin / --data.bin)"
  table-bytes := pad_ merged.to-bytes 4

  front := populated + data-size
  trailer-size := table-bytes.size + 4
  block-size := round-up trailer-size 16
  trailer-first-sector := (slot-size - block-size) / FLASH-SECTOR-SIZE_ * FLASH-SECTOR-SIZE_
  if (round-up front FLASH-SECTOR-SIZE_) > trailer-first-sector:
    throw "EC618 slot overflow: VM body 0x$(%x vm-body) + extension 0x$(%x extension.bytes.size) + .data 0x$(%x data-size) + reloc trailer 0x$(%x trailer-size) does not leave the trailer its own sector(s) in slot 0x$(%x slot-size)"

  result.replace (slot-file + vm-body) extension.bytes
  if data-size > 0: result.replace (slot-file + populated) vm-data
  result.replace (slot-file + slot-size - trailer-size) table-bytes
  size-word := ByteArray 4
  LITTLE-ENDIAN.put-uint32 size-word 0 table-bytes.size
  result.replace (slot-file + slot-size - 4) size-word

  merged.apply result
      --base=slot-file
      --delta=(slot-a-xip - link-base)
      --direction=TO-SLOT
  result += crypto.sha256 result
  return result

class Extension_:
  bytes/ByteArray
  pointer-offsets/List

  constructor .bytes .pointer-offsets:

build-extension_ -> Extension_
    --containers/List
    --system-uuid/Uuid
    --config-encoded/ByteArray
    --extension-xip-addr/int:
  image-count := containers.size
  image-table := ByteArray 8 * image-count
  header-size := 5 * 4
  pointer-offsets := []
  relocation-base := extension-xip-addr + header-size + image-table.size
  images := []
  index := 0
  containers.do: | container/Container |
    image-size := container.relocated-size
    LITTLE-ENDIAN.put-uint32 image-table (index * 8) relocation-base
    LITTLE-ENDIAN.put-uint32 image-table (index * 8 + 4) image-size
    pointer-offsets.add (header-size + index * 8)
    container-offset := relocation-base - extension-xip-addr
    pointer-offsets_ container.relocatable --word-size=WORD-SIZE:
      pointer-offsets.add (container-offset + it)
    image-bits := container.relocate
        --relocation-base=relocation-base
        --system-uuid=system-uuid
        --attach-assets
    images.add image-bits
    relocation-base += image-bits.size
    index++

  extension-header := ByteArray header-size
  LITTLE-ENDIAN.put-uint32 extension-header 0 0x98dfc301
  LITTLE-ENDIAN.put-uint32 extension-header (3 * 4) image-count
  extension := extension-header + image-table
  images.do: extension += it
  used-size := extension.size
  config-size-bytes := ByteArray 4
  LITTLE-ENDIAN.put-uint32 config-size-bytes 0 config-encoded.size
  extension += config-size-bytes
  extension += config-encoded
  LITTLE-ENDIAN.put-uint32 extension (1 * 4) used-size
  LITTLE-ENDIAN.put-uint32 extension (2 * 4) 0
  checksum := 0xb3147ee9
  4.repeat: checksum ^= LITTLE-ENDIAN.uint32 extension (it * 4)
  LITTLE-ENDIAN.put-uint32 extension (4 * 4) checksum
  return Extension_ extension pointer-offsets

verify-extension-relocation_ ext-a/Extension_
    --containers/List
    --system-uuid/Uuid
    --config-encoded/ByteArray
    --extension-xip-addr/int
    --displacement/int -> none:
  ext-b := build-extension_
      --containers=containers
      --system-uuid=system-uuid
      --config-encoded=config-encoded
      --extension-xip-addr=(extension-xip-addr + displacement)
  bytes-a := ext-a.bytes
  bytes-b := ext-b.bytes
  if bytes-a.size != bytes-b.size:
    throw "[ext-verify] extension size differs: A=$bytes-a.size B=$bytes-b.size"
  relocated := bytes-a.copy
  offsets := {}
  ext-a.pointer-offsets.do: | offset/int |
    offsets.add offset
    LITTLE-ENDIAN.put-uint32 relocated offset
        ((LITTLE-ENDIAN.uint32 relocated offset) + displacement)
  differences := 0
  reported := 0
  (bytes-a.size / 4).repeat: | i/int |
    offset := i * 4
    relocated-word := LITTLE-ENDIAN.uint32 relocated offset
    expected-word := LITTLE-ENDIAN.uint32 bytes-b offset
    if relocated-word != expected-word:
      differences++
      if reported < 40:
        original-word := LITTLE-ENDIAN.uint32 bytes-a offset
        print "[ext-verify] DIFF ext-off=0x$(%x offset): A=0x$(%x original-word) reloc=0x$(%x relocated-word) B=0x$(%x expected-word) in-pointer-offsets=$(offsets.contains offset)"
        reported++
  if differences != 0:
    throw "[ext-verify] extension relocation incomplete: $differences differing words"
  print "[ext-verify] OK: extension relocates cleanly ($(ext-a.pointer-offsets.size) pointers, $bytes-a.size bytes)"

patch-details_ result/ByteArray
    --extension-xip-addr/int
    --system-uuid/Uuid -> none:
  details-offset := image-details.find-offset result --word-size=WORD-SIZE
  LITTLE-ENDIAN.put-uint32 result details-offset extension-xip-addr
  result.replace (details-offset + 4) system-uuid.to-byte-array

pointer-offsets_ relocatable/ByteArray --word-size/int [block] -> none:
  word-bits := word-size * 8
  chunk-size := (word-bits + 1) * word-size
  relocated-offset := 0
  pos := 0
  while pos < relocatable.size:
    end := min (pos + chunk-size) relocatable.size
    mask/int := word-size == 4
        ? LITTLE-ENDIAN.uint32 relocatable pos
        : LITTLE-ENDIAN.int64 relocatable pos
    data-words := (end - pos - word-size) / word-size
    data-words.repeat:
      if (mask & (1 << it)) != 0:
        block.call (relocated-offset + it * word-size)
    relocated-offset += data-words * word-size
    pos = end

/**
Returns the logical parts of an EC618 AP image.
*/
parts firmware-bin/ByteArray -> List:
  SHA256-SIZE ::= 32
  result := []
  details-offset := image-details.find-offset firmware-bin --word-size=WORD-SIZE
  extension-addr := LITTLE-ENDIAN.uint32 firmware-bin details-offset
  if extension-addr == 0:
    result.add { "type": "binary", "from": 0, "to": firmware-bin.size }
    return result
  extension-offset := extension-addr - XIP-BASE_ - AP-LOAD-OFFSET_
  result.add { "type": "binary", "from": 0, "to": extension-offset }
  if extension-offset < firmware-bin.size:
    used := LITTLE-ENDIAN.uint32 firmware-bin extension-offset + 4
    config-end := firmware-bin.size - SHA256-SIZE
    result.add { "type": "images", "from": extension-offset, "to": extension-offset + used }
    result.add { "type": "config", "from": extension-offset + used, "to": config-end }
    result.add { "type": "checksum", "from": config-end, "to": firmware-bin.size }
  return result
