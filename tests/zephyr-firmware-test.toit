// Copyright (C) 2026 Toit contributors.
// Use of this source code is governed by a Zero-Clause BSD license in tests/LICENSE.
import expect show *
import io show LITTLE-ENDIAN
import uuid show Uuid
import ..tools.firmware.zephyr as zephyr

SDK ::= Uuid.uuid5 "test" "zephyr"

class TestContainer implements zephyr.Container:
  size/int
  with-assets/bool

  constructor .size --.with-assets=false:

  relocate --relocation-base/int --attach-assets/bool --system-uuid/Uuid -> ByteArray:
    bits := ByteArray size
    LITTLE-ENDIAN.put-uint32 bits 0 0xdeadface
    bits[8] = with-assets ? 1 : 0
    LITTLE-ENDIAN.put-uint16 bits 30 (size / 4096)
    bits.replace 32 system-uuid.to-byte-array
    // Check relocation bases independently in the resulting image.
    LITTLE-ENDIAN.put-uint32 bits 48 (relocation-base + 64)
    if with-assets:
      bits[24] = 0x80
      assets := ByteArray 4096 --initial=0x51
      LITTLE-ENDIAN.put-uint32 assets 0 17
      bits += assets
    return bits

base -> ByteArray:
  bits := ByteArray 3 * 4096
  bits.replace 64 zephyr.LAYOUT-MAGIC.to-byte-array
  LITTLE-ENDIAN.put-uint32 bits 72 1
  LITTLE-ENDIAN.put-uint32 bits 76 0x10000
  LITTLE-ENDIAN.put-uint32 bits 80 0x11000
  LITTLE-ENDIAN.put-uint32 bits 84 0x15000
  bits.replace 88 SDK.to-byte-array
  LITTLE-ENDIAN.put-uint32 bits 104 0x315a5445
  LITTLE-ENDIAN.put-uint32 bits 4096 0x98dfc301
  LITTLE-ENDIAN.put-uint32 bits 4100 8192
  LITTLE-ENDIAN.put-uint32 bits 4108 1
  LITTLE-ENDIAN.put-uint32 bits 4112 (0x98dfc301 ^ 8192 ^ 1 ^ 0xb3147ee9)
  LITTLE-ENDIAN.put-uint32 bits 4116 0x12000
  LITTLE-ENDIAN.put-uint32 bits 4120 4096
  bits.replace 8192 ((TestContainer 4096).relocate
      --relocation-base=0x12000
      --attach-assets
      --system-uuid=SDK)
  return bits

main:
  test-controller
  original := base
  result := zephyr.build-image original [(TestContainer 4096 --with-assets), TestContainer 4096]
  layout := zephyr.Layout result
  expect-equals 0x10000 layout.load-address
  expect-equals 0x11000 layout.extension-address
  expect-equals 0x15000 layout.limit
  expect-bytes-equal original[..4096] result[..4096]
  expect-equals 5 * 4096 result.size
  expect-equals 2 (LITTLE-ENDIAN.uint32 result 4108)
  expect-equals 0x12040 (LITTLE-ENDIAN.uint32 result (8192 + 48))
  expect-equals 0x14040 (LITTLE-ENDIAN.uint32 result (16384 + 48))
  expect-equals 17 (LITTLE-ENDIAN.uint32 result 12288)
  expect-equals 0x51 result[12292]
  marker-assets := result.copy
  LITTLE-ENDIAN.put-uint32 marker-assets 12288 128
  marker-assets.replace 12292 original[64..108]
  zephyr.Layout marker-assets
  shrunk := zephyr.build-image result [TestContainer 4096]
  expect-bytes-equal original shrunk
  expect-throw "Zephyr containers exceed the code partition":
    zephyr.build-image original [TestContainer 16384]
  rejects: zephyr.build-image original []
  rejects: zephyr.build-image original [TestContainer 4096, TestContainer 4096]
  // Descriptor and extension corruption must never authorize replacement.
  [64, 72, 76, 80, 84, 88, 104, 4096, 4100, 4104, 4108, 4112, 4116, 4120, 8192, 8196, 8221, 8222, 8224].do: |at|
    bad := original.copy
    bad[at] ^= 0x80
    rejects: zephyr.Layout bad
  rejects: zephyr.Layout original[..original.size - 1]
  rejects: zephyr.Layout (original + #[0])
  ambiguous := original.copy
  ambiguous.replace 128 original[64..108]
  rejects: zephyr.Layout ambiguous
  bad-assets := result.copy
  LITTLE-ENDIAN.put-uint32 bad-assets 12288 4093
  rejects: zephyr.Layout bad-assets
  expect-bytes-equal original base
  test-relocatable

test-relocatable:
  program := (TestContainer 4096 --with-assets).relocate
      --relocation-base=0
      --attach-assets
      --system-uuid=SDK
  // snapshot-to-image appends assets without setting their header flag.
  program[24] = 0
  encoded := ByteArray program.size / 128 * 132
  (program.size / 128).repeat: |index|
    encoded.replace (index * 132 + 4) program[index * 128..(index + 1) * 128]
  LITTLE-ENDIAN.put-uint32 encoded 0 (1 << 12)
  expect (zephyr.validate-relocatable encoded SDK)
  rejects: zephyr.validate-relocatable encoded (Uuid.uuid5 "test" "different-sdk")
  rejects: zephyr.validate-relocatable encoded[..encoded.size - 1] SDK
  [0, 52, 32 * 132, 32 * 132 + 4].do: |at|
    bad := encoded.copy
    LITTLE-ENDIAN.put-uint32 bad at 0xffffffff
    rejects: zephyr.validate-relocatable bad SDK

rejects [block]:
  expect ((catch: block.call) != null)

test-controller:
  controller := ByteArray 256
  LITTLE-ENDIAN.put-uint32 controller 0 0x21001000
  LITTLE-ENDIAN.put-uint32 controller 4 0x01000011
  zephyr.validate-nrf5340-controller controller
  rejects: zephyr.validate-nrf5340-controller controller[..7]
  rejects: zephyr.validate-nrf5340-controller (controller + (ByteArray 0x40000))
  [0, 0x20001000, 0x21000000, 0x21010008, 0x21001001].do: |stack|
    bad := controller.copy
    LITTLE-ENDIAN.put-uint32 bad 0 stack
    rejects: zephyr.validate-nrf5340-controller bad
  [0, 0x11, 0x01000001, 0x01000010, 0x01000101].do: |entry|
    bad := controller.copy
    LITTLE-ENDIAN.put-uint32 bad 4 entry
    rejects: zephyr.validate-nrf5340-controller bad
