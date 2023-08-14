// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import crypto.crc
import expect show *

main:
  expect-equals 0x29B1 (crc.crc16-ccitt-false "123456789")
  expect-equals 0xBB3D (crc.crc16-arc "123456789")
  expect-equals 0xE5CC (crc.crc16-aug-ccitt "123456789")
  expect-equals 0xFEE8 (crc.crc16-buypass "123456789")
  expect-equals 0x4C06 (crc.crc16-cdma2000 "123456789")
  expect-equals 0x9ECF (crc.crc16-dds110 "123456789")
  expect-equals 0x007E (crc.crc16-dect-r "123456789")
  expect-equals 0x007F (crc.crc16-dect-x "123456789")
  expect-equals 0xEA82 (crc.crc16-dnp "123456789")
  expect-equals 0xC2B7 (crc.crc16-en13757 "123456789")
  expect-equals 0xD64E (crc.crc16-genibus "123456789")
  expect-equals 0x44C2 (crc.crc16-maxim "123456789")
  expect-equals 0x6F91 (crc.crc16-mcrf4xx "123456789")
  expect-equals 0x63D0 (crc.crc16-riello "123456789")
  expect-equals 0xD0DB (crc.crc16-t10-dif "123456789")
  expect-equals 0x0FB3 (crc.crc16-teledisk "123456789")
  expect-equals 0x26B1 (crc.crc16-tms37157 "123456789")
  expect-equals 0xB4C8 (crc.crc16-usb "123456789")
  expect-equals 0xBF05 (crc.crc-a "123456789")
  expect-equals 0x2189 (crc.crc16-kermit "123456789")
  expect-equals 0x4B37 (crc.crc16-modbus "123456789")
  expect-equals 0x906E (crc.crc16-x25 "123456789")
  expect-equals 0x31C3 (crc.crc16-xmodem "123456789")
  expect-equals 0xF4 (crc.crc8 "123456789")
  expect-equals 0xDA (crc.crc8-cdma2000 "123456789")
  expect-equals 0x15 (crc.crc8-darc "123456789")
  expect-equals 0xBC (crc.crc8-dvb-s2 "123456789")
  expect-equals 0x97 (crc.crc8-ebu "123456789")
  expect-equals 0x7E (crc.crc8-i-code "123456789")
  expect-equals 0xA1 (crc.crc8-itu "123456789")
  expect-equals 0xA1 (crc.crc8-maxim "123456789")
  expect-equals 0xD0 (crc.crc8-rohc "123456789")
  expect-equals 0x25 (crc.crc8-wcdma "123456789")
  expect-equals 0xCBF43926 (crc.crc32 "123456789")
  expect-equals 0xFC891918 (crc.crc32-bzip2 "123456789")
  expect-equals 0xE3069283 (crc.crc32c "123456789")
  expect-equals 0x87315576 (crc.crc32d "123456789")
  expect-equals 0x340BC6D9 (crc.crc32-jamcrc "123456789")
  expect-equals 0x0376E6E7 (crc.crc32-mpeg2 "123456789")
  expect-equals 0x765E7680 (crc.crc32-posix "123456789")
  expect-equals 0x3010BF7F (crc.crc32q "123456789")
  expect-equals 0xBD0BE338 (crc.crc32-xfer "123456789")
  expect-equals 0x995dc9bbdf1939fa (crc.crc64-xz "123456789")

  // The 64 bit CRC from the Go progamming language, with the polynomial
  // expressed in normalized order.
  summer := crc.Crc.little-endian 64
      --normal-polynomial=0x0000_0000_0000_001b
      --initial-state=0xffff_ffff_ffff_ffff
      --xor-result=0xffff_ffff_ffff_ffff
  summer.add "123456789"
  expect-equals 0xb90956c775a41001 summer.get-as-int

  // The 64 bit CRC from the Go progamming language, with the polynomial
  // expressed in little endian order.
  summer = crc.Crc.little-endian 64
      --polynomial=0xd800_0000_0000_0000
      --initial-state=0xffff_ffff_ffff_ffff
      --xor-result=0xffff_ffff_ffff_ffff
  summer.add "123456789"
  expect-equals 0xb90956c775a41001 summer.get-as-int

  // The 64 bit CRC from ECMA182 used in tape cartridges.
  9.repeat: | cut |
    summer = crc.Crc.big-endian 64 --polynomial=0x42f0e1eba9ea3693
    summer.add "123456789"[..cut]
    summer2 := summer.clone
    summer.add "123456789"[cut..]
    summer2.add "123456789"[cut..]
    expect-equals 0x6c40df5f0b497347 summer.get-as-int
    expect-equals 0x6c40df5f0b497347 summer2.get-as-int

  // The 5 bit CRC from USB, little-endian polynomial 0b00101.
  summer = crc.Crc.little-endian 5 --normal-polynomial=0x5 --initial-state=0x1f --xor-result=0x1f
  summer.add "123456789"
  expect-equals 0x19 summer.get-as-int

  // The 5 bit CRC from USB, polynomial 0b1_10100.
  summer = crc.Crc.little-endian 5 --polynomial=0x14 --initial-state=0x1f --xor-result=0x1f
  summer.add "123456789"
  expect-equals 0x19 summer.get-as-int
