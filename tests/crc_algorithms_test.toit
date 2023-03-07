// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import crypto.crc
import expect show *

main:
  expect_equals 0x29B1 (crc.crc16_ccitt_false "123456789")
  expect_equals 0xBB3D (crc.crc16_arc "123456789")
  expect_equals 0xE5CC (crc.crc16_aug_ccitt "123456789")
  expect_equals 0xFEE8 (crc.crc16_buypass "123456789")
  expect_equals 0x4C06 (crc.crc16_cdma2000 "123456789")
  expect_equals 0x9ECF (crc.crc16_dds110 "123456789")
  expect_equals 0x007E (crc.crc16_dect_r "123456789")
  expect_equals 0x007F (crc.crc16_dect_x "123456789")
  expect_equals 0xEA82 (crc.crc16_dnp "123456789")
  expect_equals 0xC2B7 (crc.crc16_en13757 "123456789")
  expect_equals 0xD64E (crc.crc16_genibus "123456789")
  expect_equals 0x44C2 (crc.crc16_maxim "123456789")
  expect_equals 0x6F91 (crc.crc16_mcrf4xx "123456789")
  expect_equals 0x63D0 (crc.crc16_riello "123456789")
  expect_equals 0xD0DB (crc.crc16_t10_dif "123456789")
  expect_equals 0x0FB3 (crc.crc16_teledisk "123456789")
  expect_equals 0x26B1 (crc.crc16_tms37157 "123456789")
  expect_equals 0xB4C8 (crc.crc16_usb "123456789")
  expect_equals 0xBF05 (crc.crc_a "123456789")
  expect_equals 0x2189 (crc.crc16_kermit "123456789")
  expect_equals 0x4B37 (crc.crc16_modbus "123456789")
  expect_equals 0x906E (crc.crc16_x25 "123456789")
  expect_equals 0x31C3 (crc.crc16_xmodem "123456789")
  expect_equals 0xF4 (crc.crc8 "123456789")
  expect_equals 0xDA (crc.crc8_cdma2000 "123456789")
  expect_equals 0x15 (crc.crc8_darc "123456789")
  expect_equals 0xBC (crc.crc8_dvb_s2 "123456789")
  expect_equals 0x97 (crc.crc8_ebu "123456789")
  expect_equals 0x7E (crc.crc8_i_code "123456789")
  expect_equals 0xA1 (crc.crc8_itu "123456789")
  expect_equals 0xA1 (crc.crc8_maxim "123456789")
  expect_equals 0xD0 (crc.crc8_rohc "123456789")
  expect_equals 0x25 (crc.crc8_wcdma "123456789")
  expect_equals 0xCBF43926 (crc.crc32 "123456789")
  expect_equals 0xFC891918 (crc.crc32_bzip2 "123456789")
  expect_equals 0xE3069283 (crc.crc32c "123456789")
  expect_equals 0x87315576 (crc.crc32d "123456789")
  expect_equals 0x340BC6D9 (crc.crc32_jamcrc "123456789")
  expect_equals 0x0376E6E7 (crc.crc32_mpeg2 "123456789")
  expect_equals 0x765E7680 (crc.crc32_posix "123456789")
  expect_equals 0x3010BF7F (crc.crc32q "123456789")
  expect_equals 0xBD0BE338 (crc.crc32_xfer "123456789")
  expect_equals 0x995dc9bbdf1939fa (crc.crc64_xz "123456789")

  // The 64 bit CRC from the Go progamming language, with the polynomial
  // expressed in normalized order.
  summer := crc.Crc.little_endian 64
      --normal_polynomial=0x0000_0000_0000_001b
      --initial_state=0xffff_ffff_ffff_ffff
      --xor_result=0xffff_ffff_ffff_ffff
  summer.add "123456789"
  expect_equals 0xb90956c775a41001 summer.get_as_int

  // The 64 bit CRC from the Go progamming language, with the polynomial
  // expressed in little endian order.
  summer = crc.Crc.little_endian 64
      --polynomial=0xd800_0000_0000_0000
      --initial_state=0xffff_ffff_ffff_ffff
      --xor_result=0xffff_ffff_ffff_ffff
  summer.add "123456789"
  expect_equals 0xb90956c775a41001 summer.get_as_int

  // The 64 bit CRC from ECMA182 used in tape cartridges.
  summer = crc.Crc.big_endian 64 --polynomial=0x42f0e1eba9ea3693
  summer.add "123456789"
  expect_equals 0x6c40df5f0b497347 summer.get_as_int

  // The 5 bit CRC from USB, little-endian polynomial 0b00101.
  summer = crc.Crc.little_endian 5 --normal_polynomial=0x5 --initial_state=0x1f --xor_result=0x1f
  summer.add "123456789"
  expect_equals 0x19 summer.get_as_int

  // The 5 bit CRC from USB, polynomial 0b1_10100.
  summer = crc.Crc.little_endian 5 --polynomial=0x14 --initial_state=0x1f --xor_result=0x1f
  summer.add "123456789"
  expect_equals 0x19 summer.get_as_int
