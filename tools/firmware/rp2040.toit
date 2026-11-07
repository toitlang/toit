// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the LGPL-2.1 license in LICENSE.
import io show LITTLE-ENDIAN
import uuid show Uuid
import .container show Container

WORD-SIZE ::= 4
XIP-BASE_ ::= 0x1002_0000
SLOT-SIZE_ ::= 0xf0000

word_ bytes/ByteArray at/int -> int:
  return LITTLE-ENDIAN.uint32 bytes at

put_ bytes/ByteArray at/int value/int -> none:
  LITTLE-ENDIAN.put-uint32 bytes at value

validate-envelope-base bytes/ByteArray -> none:
  if not (264 <= bytes.size <= SLOT-SIZE_) or bytes.size & 3 != 0:
    throw "Invalid RP2040 application size"
  stack := word_ bytes 256
  entry := word_ bytes 260
  if not (0x2000_0000 < stack <= 0x2004_2000) or stack & 7 != 0 or
      entry & 1 == 0 or not (XIP-BASE_ + 264 <= entry < XIP-BASE_ + bytes.size):
    throw "Invalid RP2040 application vectors (expected link address 0x10020000)"
  details-offset_ bytes

details-offset_ bytes/ByteArray -> int:
  found/int? := null
  for offset := 0; offset + 28 <= bytes.size; offset += 4:
    if (word_ bytes offset) != 0x7017_da7a: continue
    if (word_ bytes (offset + 24)) != 0x00c0_9f19: continue
    if found != null: throw "Ambiguous RP2040 image-details marker"
    found = offset + 4
  if found == null: throw "Missing RP2040 image-details marker"
  return found

build-extension_ containers/List system-uuid/Uuid config/ByteArray base/int -> ByteArray:
  if containers.is-empty: throw "RP2040 firmware requires a system container"
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
    if result.size > SLOT-SIZE_: throw "RP2040 containers exceed firmware slot"
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


/** Appends relocated containers and configuration without moving native code. */
build-image -> ByteArray
    --binary-input/ByteArray
    --containers/List
    --system-uuid/Uuid
    --config-encoded/ByteArray:
  validate-envelope-base binary-input
  details := details-offset_ binary-input
  if (word_ binary-input details) != 0:
    throw "RP2040 envelope base must not already contain an extracted extension"
  offset := round-up binary-input.size 4096
  extension := build-extension_ containers system-uuid config-encoded (XIP-BASE_ + offset)
  if offset + extension.size > SLOT-SIZE_: throw "RP2040 image exceeds the 960 KiB application slot"
  result := binary-input.copy
  result += ByteArray (offset - result.size)
  result += extension
  put_ result details (XIP-BASE_ + offset)
  result.replace (details + 4) system-uuid.to-byte-array
  validate-envelope-base result
  return result

parts bytes/ByteArray -> List:
  validate-envelope-base bytes
  extension := (word_ bytes (details-offset_ bytes)) - XIP-BASE_
  if extension < 264 or extension + 20 > bytes.size:
    throw "Invalid RP2040 firmware extension"
  used := word_ bytes (extension + 4)
  free := word_ bytes (extension + 8)
  if used < 20 or extension + used + free != bytes.size:
    throw "Invalid RP2040 firmware extension bounds"
  return [
    {"type": "binary", "from": 0, "to": extension},
    {"type": "images", "from": extension, "to": extension + used},
    {"type": "config", "from": extension + used, "to": bytes.size},
  ]
