// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by the Zero-Clause BSD license in tests/LICENSE.
import crypto.sha256 show Sha256
import system.firmware

STATE ::= "toit-rp2040-test/stream-firmware"

current-digest -> ByteArray:
  digest/ByteArray? := null
  firmware.map: | mapping/firmware.FirmwareMapping |
    hash := Sha256
    for from := 0; from < mapping.size; from += 1024:
      count := min 1024 (mapping.size - from)
      bytes := ByteArray count
      mapping.copy from (from + count) --into=bytes
      hash.add bytes
    digest = hash.get
  return digest as ByteArray
