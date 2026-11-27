// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.

import crypto.sha256 show Sha256 sha256
import encoding.json
import expect show *
import host.file
import io show LITTLE-ENDIAN

START ::= 0xffff_ded3
TBYB ::= 0x8000_0000
FAMILY ::= 0xe48b_ff57

word data/ByteArray at/int -> int: return LITTLE-ENDIAN.uint32 data at
put data/ByteArray at/int value/int: LITTLE-ENDIAN.put-uint32 data at value

root-and-terminal data/ByteArray -> List:
  roots := []
  for at := 0; at < (min 4096 data.size); at += 4:
    if (word data at) == START: roots.add at
  expect-equals 1 roots.size
  root := roots[0]
  at := root + 8
  while at + 12 <= data.size:
    header := word data at
    tag := header & 0xff
    words := (header >> 8) & (tag & 0x80 != 0 ? 0xffff : 0xff)
    if tag == 0xff: return [root, root + (LITTLE-ENDIAN.int32 data (at + 4))]
    expect (words > 0)
    at += words * 4
  throw "Root image definition has no footer"

verify-rom-hash data/ByteArray terminal/int:
  at := terminal + 8
  ranges := []
  hash-size := null
  digest-offset := null
  while at + 12 <= data.size:
    header := word data at
    tag := header & 0xff
    words := (header >> 8) & (tag & 0x80 != 0 ? 0xffff : 0xff)
    if tag == 0xff: break
    expect (words > 0 and at + words * 4 <= data.size)
    if tag == 0x06:
      count := header >> 24
      expect-equals (1 + 3 * count) words
      count.repeat: |index|
        entry := at + 4 + index * 12
        relative := LITTLE-ENDIAN.int32 data entry
        ranges.add [at + relative, word data (entry + 8)]
    else if tag == 0x47:
      hash-size = (word data (at + 4)) * 4
    else if tag == 0x4b:
      digest-offset = at + 4
    at += words * 4
  expect (ranges.size > 0 and hash-size != null and digest-offset != null)
  digest := Sha256
  ranges.do: |range| digest.add data range[0] (range[0] + range[1])
  definition := data.copy terminal (terminal + hash-size)
  definition[7] &= 0x7f
  digest.add definition
  expect-equals data[digest-offset..digest-offset + 32] digest.get

mutate mode/string source/string output/string:
  data := file.read-contents source
  if mode == "partition-hash" or mode == "partition-layout":
    expect-equals 512 data.size
    if mode == "partition-hash":
      data[32 + 0x70] ^= 0x80
    else:
      // Alter the layout while retaining a valid partition table digest.
      put data (32 + 0x0c) ((word data (32 + 0x0c)) ^ 1)
      data.replace (32 + 0x70) (sha256 data[32..32 + 0x6c])
  else:
    offsets := root-and-terminal data
    if mode == "hash":
      data[data.size - 13] ^= 0x80
    else if mode == "root-tbyb" or mode == "terminal-tbyb":
      offset := offsets[mode == "root-tbyb" ? 0 : 1] + 4
      put data offset ((word data offset) & ~TBYB)
    else:
      throw "Unknown mutation: $mode"
  file.write-contents data --path=output

verify-show path/string assets-path/string:
  document := json.decode (file.read-contents path)
  expect-equals 1001 document["envelope-format-version"]
  expect-equals "rp2350" document["kind"]
  containers := document["containers"]
  ["system", "child"].do: |name|
    expect-structural-equals ["trigger=boot", "critical"] containers[name]["flags"]
  expect-equals (file.size assets-path) containers["child"]["assets"]["size"]

uf2-header data/ByteArray index/int -> List:
  start := index * 512
  expect (start + 512 <= data.size)
  values := List 8: word data (start + it * 4)
  expect-equals 0x0a32_4655 values[0]
  expect-equals 0x9e5d_5157 values[1]
  expect-equals 0x0ab1_6f30 (word data (start + 508))
  return values

verify-uf2 path/string firmware-path/string partition-path/string:
  data := file.read-contents path
  firmware := file.read-contents firmware-path
  partition := file.read-contents partition-path
  firmware-blocks := (firmware.size + 255) / 256
  main-blocks := 1 + firmware-blocks
  expect-equals ((main-blocks + 1) * 512) data.size
  absolute := uf2-header data 0
  expect-structural-equals [0xa000, 0x10ff_ff00, 256, 0, 2, FAMILY] absolute[2..]
  expect-equals (ByteArray 256 --initial=0xef) data[32..288]
  expect-equals 0x9957_e304 (word data 288)
  reconstructed := ByteArray (firmware-blocks * 256)
  main-blocks.repeat: |index|
    values := uf2-header data (index + 1)
    target := index == 0 ? 0x1000_0000 : 0x1000_2000 + (index - 1) * 256
    expect-structural-equals [0x2000, target, 256, index, main-blocks, FAMILY] values[2..]
    start := (index + 1) * 512 + 32
    payload := data[start..start + 256]
    if index == 0:
      expect-equals partition[32..288] payload
    else:
      reconstructed.replace ((index - 1) * 256) payload
  recovery := reconstructed[..firmware.size]
  expected := firmware.copy
  offsets := root-and-terminal expected
  root := offsets[0]
  terminal := offsets[1]
  expect ((word expected (root + 4)) & TBYB != 0)
  expect ((word expected (terminal + 4)) & TBYB != 0)
  put expected (terminal + 4) ((word expected (terminal + 4)) & ~TBYB)
  expect-equals expected recovery
  expect ((word recovery (root + 4)) & TBYB != 0)
  expect-equals 0 ((word recovery (terminal + 4)) & TBYB)
  verify-rom-hash recovery terminal
  reconstructed[firmware.size..].do: expect-equals 0 it
  expect (0x2000 + firmware-blocks * 256 <= 0x402000)
  print "envelope-fixture: PASS recovery UF2 and ROM hash"

main args/List:
  if args.size == 4 and args[0] == "mutate":
    mutate args[1] args[2] args[3]
  else if args.size == 3 and args[0] == "verify-show":
    verify-show args[1] args[2]
  else if args.size == 4 and args[0] == "verify-uf2":
    verify-uf2 args[1] args[2] args[3]
  else:
    throw "Usage: envelope-fixture mutate MODE INPUT OUTPUT | verify-show SHOW.json ASSETS | verify-uf2 IMAGE.uf2 FIRMWARE.bin PARTITIONS.uf2"
