// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.

import encoding.ubjson
import host.file
import io show LITTLE-ENDIAN
import system.assets as system-assets

XIP-BASE ::= 0x1000_0000

contains-bytes haystack/ByteArray needle/ByteArray -> bool:
  if needle.is-empty: return true
  for start := 0; start + needle.size <= haystack.size; start++:
    matches := true
    for offset := 0; offset < needle.size; offset++:
      if haystack[start + offset] != needle[offset]:
        matches = false
        break
    if matches: return true
  return false

make-assets output/string size/int -> none:
  value := size == 0 ? "rp2350-envelope-assets".to-byte-array : ByteArray size
  file.write-contents --path=output (system-assets.encode {"payload": value})

verify-output ubjson-path/string binary-path/string assets-path/string -> none:
  document := ubjson.decode (file.read-contents ubjson-path)
  binary := file.read-contents binary-path
  assert: document["binary"] == binary

  parts/List := document["parts"]
  assert: parts.map: it["type"] == ["binary", "images", "config", "checksum"]

  images := parts[1]
  images-from/int := images["from"]
  assert: (LITTLE-ENDIAN.uint32 binary (images-from + 12)) == 2

  // The system image is first and the installed child is second. Both are
  // boot-critical, and both carry assets: the system image has the child UUID
  // map while the child has the explicit test assets.
  system-offset := (LITTLE-ENDIAN.uint32 binary (images-from + 20)) - XIP-BASE
  child-offset := (LITTLE-ENDIAN.uint32 binary (images-from + 28)) - XIP-BASE
  child-size := LITTLE-ENDIAN.uint32 binary (images-from + 32)
  assert: (binary[system-offset + 24] & 0x83) == 0x83
  assert: (binary[child-offset + 24] & 0x83) == 0x83

  assets := file.read-contents assets-path
  assert: contains-bytes binary[child-offset..child-offset + child-size] assets

  config := parts[2]
  config-from/int := config["from"]
  config-size := LITTLE-ENDIAN.uint32 binary config-from
  config-document := ubjson.decode binary[config-from + 4..config-from + 4 + config-size]
  assert: config-document["enabled"] == true
  assert: config-document["name"] == "rp2350-envelope-test"

main arguments/List:
  if arguments.size == 3 and arguments[0] == "make-assets":
    make-assets arguments[1] (int.parse arguments[2])
    return
  if arguments.size == 4 and arguments[0] == "verify-output":
    verify-output arguments[1] arguments[2] arguments[3]
    return
  throw "usage: envelope_test_helper.toit make-assets OUTPUT SIZE | verify-output UBJSON BINARY ASSETS"
