// Copyright (C) 2024 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import ble show *
import expect show *

main:
  test-data-blocks
  test-advertisement-packets
  test-real-world-examples

test-data-blocks:
  uuid16-1 := BleUuid "1234"
  uuid16-2 := BleUuid "5678"
  uuid32-1 := BleUuid "12345678"
  uuid32-2 := BleUuid "9ABCDEF0"
  uuid128-1 := BleUuid "12345678-9ABC-DEF0-4444-0FEDCBA98765"
  uuid128-2 := BleUuid "FEDCBA98-7654-3210-4444-123456789ABC"

  block := DataBlock.flags 0
  expect-equals #[0x01, 0x01] block.to-raw
  expect block.is-flags
  expect-equals 0 block.flags

  block = DataBlock.flags BLE-ADVERTISE-FLAGS-BREDR-UNSUPPORTED
  expect-equals #[0x02, 0x01, 0x04] block.to-raw
  expect-equals 0x04 BLE-ADVERTISE-FLAGS-BREDR-UNSUPPORTED
  expect block.is-flags
  expect-equals 0x04 block.flags

  block = DataBlock.flags BLE-ADVERTISE-FLAGS-GENERAL-DISCOVERY
  expect-equals #[0x02, 0x01, 0x02] block.to-raw
  expect-equals 0x02 BLE-ADVERTISE-FLAGS-GENERAL-DISCOVERY
  expect block.is-flags
  expect-equals 0x02 block.flags

  // By default, the 'flags' constructor with named arguments sets the BR/EDR
  // unsupported flag.
  block = DataBlock.flags --limited-discovery
  expect-equals #[0x02, 0x01, 0x01 | 0x04] block.to-raw
  expect block.is-flags
  expect-equals (0x01 | 0x04) block.flags

  block = DataBlock.flags --bredr-supported --limited-discovery
  expect-equals #[0x02, 0x01, 0x01] block.to-raw
  expect block.is-flags
  expect-equals 0x01 block.flags

  block = DataBlock.services-16 []
  expect-equals #[0x01, 0x03] block.to-raw
  expect block.is-services-16
  expect block.is-services
  expect block.services.is-empty
  expect block.services-16.is-empty
  expect-not (block.contains-service uuid16-1)
  expect-not (block.contains-service uuid16-2)

  block = DataBlock.services-16 [] --incomplete
  expect-equals #[0x01, 0x02] block.to-raw
  expect block.is-services-16
  expect block.is-services
  expect block.services.is-empty
  expect block.services-16.is-empty
  expect-not (block.contains-service uuid16-1)
  expect-not (block.contains-service uuid16-2)

  block = DataBlock.services-16 [uuid16-1]
  expect-equals #[0x03, 0x03, 0x34, 0x12] block.to-raw
  expect block.is-services-16
  expect block.is-services
  expect-not block.services.is-empty
  expect-not block.services-16.is-empty
  expect-equals [uuid16-1] block.services-16
  expect-equals [uuid16-1] block.services
  expect (block.contains-service uuid16-1)
  expect-not (block.contains-service uuid16-2)

  block = DataBlock.services-16 [uuid16-1, uuid16-2]
  expect-equals #[0x05, 0x03, 0x34, 0x12, 0x78, 0x56] block.to-raw
  expect block.is-services-16
  expect block.is-services
  expect-not block.services.is-empty
  expect-not block.services-16.is-empty
  expect-equals [uuid16-1, uuid16-2] block.services-16
  expect-equals [uuid16-1, uuid16-2] block.services
  expect (block.contains-service uuid16-1)
  expect (block.contains-service uuid16-2)

  block = DataBlock.services-32 []
  expect-equals #[0x01, 0x05] block.to-raw
  expect block.is-services-32
  expect block.is-services
  expect block.services.is-empty
  expect block.services-32.is-empty
  expect-not (block.contains-service uuid32-1)
  expect-not (block.contains-service uuid32-2)

  block = DataBlock.services-32 [] --incomplete
  expect-equals #[0x01, 0x04] block.to-raw
  expect block.is-services-32
  expect block.is-services
  expect block.services.is-empty
  expect block.services-32.is-empty
  expect-not (block.contains-service uuid32-1)
  expect-not (block.contains-service uuid32-2)

  block = DataBlock.services-32 [uuid32-1]
  expect-equals #[0x05, 0x05, 0x78, 0x56, 0x34, 0x12] block.to-raw
  expect block.is-services-32
  expect block.is-services
  expect-not block.services.is-empty
  expect-not block.services-32.is-empty
  expect-equals [uuid32-1] block.services-32
  expect-equals [uuid32-1] block.services
  expect (block.contains-service uuid32-1)
  expect-not (block.contains-service uuid32-2)

  block = DataBlock.services-32 [uuid32-1, uuid32-2]
  expect-equals #[0x09, 0x05, 0x78, 0x56, 0x34, 0x12, 0xF0, 0xDE, 0xBC, 0x9A] block.to-raw
  expect block.is-services-32
  expect block.is-services
  expect-not block.services.is-empty
  expect-not block.services-32.is-empty
  expect-equals [uuid32-1, uuid32-2] block.services-32
  expect-equals [uuid32-1, uuid32-2] block.services
  expect (block.contains-service uuid32-1)
  expect (block.contains-service uuid32-2)

  block = DataBlock.services-128 []
  expect-equals #[0x01, 0x07] block.to-raw
  expect block.is-services-128
  expect block.is-services
  expect block.services.is-empty
  expect block.services-128.is-empty
  expect-not (block.contains-service uuid128-1)
  expect-not (block.contains-service uuid128-2)

  block = DataBlock.services-128 [] --incomplete
  expect-equals #[0x01, 0x06] block.to-raw
  expect block.is-services-128
  expect block.is-services
  expect block.services.is-empty
  expect block.services-128.is-empty
  expect-not (block.contains-service uuid128-1)
  expect-not (block.contains-service uuid128-2)

  block = DataBlock.services-128 [uuid128-1]
  expect-equals #[
                  0x11, 0x07,
                  0x65, 0x87, 0xa9, 0xcb, 0xed, 0x0f, 0x44, 0x44,
                  0xf0, 0xde, 0xbc, 0x9a, 0x78, 0x56, 0x34, 0x12,
                ]
                block.to-raw
  expect block.is-services-128
  expect block.is-services
  expect-not block.services.is-empty
  expect-not block.services-128.is-empty
  expect-equals [uuid128-1] block.services-128
  expect-equals [uuid128-1] block.services
  expect (block.contains-service uuid128-1)
  expect-not (block.contains-service uuid128-2)

  block = DataBlock.services-128 [uuid128-1, uuid128-2]
  expect-equals #[
                  0x21, 0x07,
                  0x65, 0x87, 0xa9, 0xcb, 0xed, 0x0f, 0x44, 0x44,
                  0xf0, 0xde, 0xbc, 0x9a, 0x78, 0x56, 0x34, 0x12,
                  0xbc, 0x9a, 0x78, 0x56, 0x34, 0x12, 0x44, 0x44,
                  0x10, 0x32, 0x54, 0x76, 0x98, 0xba, 0xdc, 0xfe,
                ]
                block.to-raw
  expect block.is-services-128
  expect block.is-services
  expect-not block.services.is-empty
  expect-not block.services-128.is-empty
  expect-equals [uuid128-1, uuid128-2] block.services-128
  expect-equals [uuid128-1, uuid128-2] block.services
  expect (block.contains-service uuid128-1)
  expect (block.contains-service uuid128-2)

  block = DataBlock.name "foobar"
  expect-equals #[0x07, 0x09, 0x66, 0x6f, 0x6f, 0x62, 0x61, 0x72] block.to-raw
  expect block.is-name
  expect-equals "foobar" block.name

  block = DataBlock.name "fooba" --shortened
  expect-equals #[0x06, 0x08, 0x66, 0x6f, 0x6f, 0x62, 0x61] block.to-raw
  expect block.is-name
  expect-equals "fooba" block.name

  block = DataBlock.tx-power-level 42
  expect-equals #[0x02, 0x0A, 0x2A] block.to-raw
  expect block.is-tx-power-level
  expect-equals 42 block.tx-power-level

  block = DataBlock.tx-power-level -5
  expect-equals #[0x02, 0x0A, 0xfb] block.to-raw
  expect block.is-tx-power-level
  expect-equals -5 block.tx-power-level

  block = DataBlock.service-data uuid16-1 #[0x01, 0x02, 0x03]
  expect-equals #[0x06, 0x16, 0x34, 0x12, 0x01, 0x02, 0x03] block.to-raw
  expect block.is-service-data
  data := block.service-data: | uuid data |
    expect-equals uuid16-1 uuid
    expect-equals #[0x01, 0x02, 0x03] data
    data
  expect-equals #[0x01, 0x02, 0x03] data
  uuid := block.service-data: | uuid data | uuid
  expect-equals uuid16-1 uuid

  block = DataBlock.service-data uuid32-1 #[0x01, 0x02, 0x03]
  expect-equals #[0x08, 0x20, 0x78, 0x56, 0x34, 0x12, 0x01, 0x02, 0x03] block.to-raw
  expect block.is-service-data
  data = block.service-data: | uuid data |
    expect-equals uuid32-1 uuid
    expect-equals #[0x01, 0x02, 0x03] data
    data
  expect-equals #[0x01, 0x02, 0x03] data

  block = DataBlock.service-data uuid128-1 #[0x01, 0x02, 0x03]
  expect-equals #[
                  0x14, 0x21,
                  0x65, 0x87, 0xa9, 0xcb, 0xed, 0x0f, 0x44, 0x44,
                  0xf0, 0xde, 0xbc, 0x9a, 0x78, 0x56, 0x34, 0x12,
                  0x01, 0x02, 0x03,
                ]
                block.to-raw
  expect block.is-service-data
  data = block.service-data: | uuid data |
    expect-equals uuid128-1 uuid
    expect-equals #[0x01, 0x02, 0x03] data
    data
  expect-equals #[0x01, 0x02, 0x03] data

  // By default use 0xff, 0xff as the manufacturer ID.
  block = DataBlock.manufacturer-specific #[0x01, 0x02, 0x03]
  expect-equals #[0x06, 0xff, 0xff, 0xff, 0x01, 0x02, 0x03] block.to-raw
  expect block.is-manufacturer-specific
  block.manufacturer-specific: | id data |
    expect-equals #[0xff, 0xff] id
    expect-equals #[0x01, 0x02, 0x03] data

  block = DataBlock.manufacturer-specific #[0x01, 0x02, 0x03] --company-id=#[0x04, 0x05]
  expect-equals #[0x06, 0xff, 0x04, 0x05, 0x01, 0x02, 0x03] block.to-raw
  expect block.is-manufacturer-specific
  block.manufacturer-specific: | id data |
    expect-equals #[0x04, 0x05] id
    expect-equals #[0x01, 0x02, 0x03] data

test-advertisement-packets:
  packet := Advertisement [DataBlock.flags BLE-ADVERTISE-FLAGS-BREDR-UNSUPPORTED]
  expect-equals #[
                  0x02, 0x01, 0x04,
                ]
                packet.to-raw
  expect-null packet.name
  expect packet.services.is-empty
  expect-equals 0x04 packet.flags
  packet.manufacturer-specific: unreachable
  expect-equals [] packet.services
  expect-equals packet.to-raw (Advertisement.raw packet.to-raw).to-raw

  packet = Advertisement [
    DataBlock.flags --limited-discovery,
    DataBlock.name "foobar",
    DataBlock.manufacturer-specific #[0x01, 0x02, 0x03],
  ]
  expect-equals #[
                  0x02, 0x01, 0x01 | 0x04,  // Flags
                  0x07, 0x09, 0x66, 0x6f, 0x6f, 0x62, 0x61, 0x72,  // Name
                  0x06, 0xff, 0xff, 0xff, 0x01, 0x02, 0x03,  // Manufacturer specific
                ]
                packet.to-raw
  expect-equals packet.to-raw (Advertisement.raw packet.to-raw).to-raw

  // 27 bytes are fine.
  packet = Advertisement [
    DataBlock.manufacturer-specific (ByteArray 27),
  ]
  expect-throw "PACKET_SIZE_EXCEEDED":
    Advertisement [
      DataBlock.manufacturer-specific (ByteArray 28)
    ]

  // We can ignore the check.
  packet = Advertisement --no-check-size [
    DataBlock.manufacturer-specific (ByteArray 28)
  ]

test-real-world-examples:
  // Some packets from
  // https://jimmywongiot.com/2019/08/13/advertising-payload-format-on-ble/

  company-id := #[0x59, 0x00]  // Nordic Semiconductor.
  manufacturer-data := #[
    0x01, 0xc0, 0x11, 0x11, 0x11, 0xcc, 0x64,
    0xf0, 0xa0, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
    0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16,
    0x17, 0x18, 0x07,
  ]
  real := #[
    0x02, 0x01, 0x06,  // Flags.
    0x1b, 0xff,  // Manufacturer Specific.
  ] + company-id + manufacturer-data

  packet := Advertisement [
    DataBlock.flags --general-discovery --bredr-supported=false,
    DataBlock.manufacturer-specific --company-id=company-id manufacturer-data
  ]
  expect-equals 0x06 packet.flags
  expect-equals manufacturer-data
    (packet.manufacturer-specific: | id data |
      expect-equals company-id id
      data)

  expect-equals real packet.to-raw
  expect-equals real (Advertisement.raw packet.to-raw).to-raw


  real = #[
    0x02, 0x01, 0x05,  // Flags.
    0x02, 0x0a, 0xfc,  // Tx Power Level.
    0x05, 0x12, 0x06, 0x00, 0x14, 0x00,  // Slave connection interval range.
  ]

  packet = Advertisement [
    DataBlock.flags --limited-discovery --bredr-supported=false,
    DataBlock.tx-power-level -4,
    DataBlock 0x12 #[0x06, 0x00, 0x14, 0x00],
  ]
  expect-equals 0x05 packet.flags
  expect-equals -4 packet.tx-power-level

  expect-equals real packet.to-raw
  expect-equals real (Advertisement.raw packet.to-raw).to-raw

  expect-equals 3 packet.data-blocks.size


  real = #[
    0x11, 0x07, 0x9e, 0xca, 0xdc, 0x24, 0x0e, 0xe5, 0xa9, 0xe0, 0x93, 0xf3, 0xa3, 0xb5, 0x01, 0x00, 0x40, 0x6e,  // Services.
  ]
  uuid := BleUuid "6e400001-b5a3-f393-e0a9-e50e24dcca9e"

  packet = Advertisement [
    DataBlock.services-128 [uuid],
  ]
  expect-equals [uuid] packet.services

  expect-equals real packet.to-raw
  expect-equals real (Advertisement.raw packet.to-raw).to-raw


  real = #[
    0x11, 0x07, 0x9e, 0xca, 0xdc, 0x24, 0x0e, 0xe5, 0xa9, 0xe0, 0x93, 0xf3, 0xa3, 0xb5, 0x01, 0x00, 0x40, 0x6e,  // Services.
    0x0c, 0x09, 0x4e, 0x6f, 0x72, 0x64, 0x69, 0x63, 0x5f, 0x55, 0x41, 0x52, 0x54,  // Name.
  ]
  packet = Advertisement [
    DataBlock.services-128 [uuid],
    DataBlock.name "Nordic_UART",
  ]
  expect-equals [uuid] packet.services
  expect-equals "Nordic_UART" packet.name

  expect-equals real packet.to-raw
  expect-equals real (Advertisement.raw packet.to-raw).to-raw
