// Copyright (C) 2021 Toitware ApS. All rights reserved.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import binary show LITTLE_ENDIAN BIG_ENDIAN
import expect show *
import serial.registers show Registers

class TestRegisters extends Registers:
  lo_regs := List 16: 0
  hi_regs := List 16: 0
  hi_word_regs := List 16: 0

  read_bytes reg/int count/int -> ByteArray:
    return read_bytes reg count: throw "wham!"

  read_bytes reg/int count/int [failure] -> ByteArray:
    if count == 1:
      return ByteArray 1: lo_regs[reg]
    if count == 2:
      ba := ByteArray 2
      ba[0] = lo_regs[reg]
      ba[1] = hi_regs[reg]
      return ba
    if count == 3:
      ba := ByteArray 3
      ba[0] = lo_regs[reg]
      ba[1] = hi_regs[reg]
      ba[2] = hi_word_regs[reg] & 0xff
      return ba
    if count == 4:
      ba := ByteArray 4
      ba[0] = lo_regs[reg]
      ba[1] = hi_regs[reg]
      ba[2] = hi_word_regs[reg] & 0xff
      ba[3] = hi_word_regs[reg] >> 8
      return ba
    return failure.call

  write_bytes reg/int data/ByteArray -> none:
    if data.size > 4: throw "OUT_OF_RANGE"
    if data.size > 0: lo_regs[reg] = data[0]
    if data.size > 1: hi_regs[reg] = data[1]
    if data.size > 2:
      value := hi_word_regs[reg]
      value &= 0xff00
      value |= data[2]
      hi_word_regs[reg] = value
    if data.size > 3:
      value := hi_word_regs[reg]
      value &= 0x00ff
      value |= data[3] << 8
      hi_word_regs[reg] = value

main:
  regs := TestRegisters
  expect_equals 0
    regs.read_u8 0
  expect_equals 0
    regs.read_u8 15

  expect_equals 0
    regs.read_i8 0
  expect_equals 0
    regs.read_i8 15

  regs.write_u8 12 42

  expect_equals 0
    regs.read_u8 0
  expect_equals 42
    regs.read_u8 12
  expect_equals 42
    regs.read_i8 12

  regs.write_u8 11 255
  expect_equals 255
    regs.read_u8 11
  expect_equals -1
    regs.read_i8 11

  regs.write_i16_le 4 1234
  expect_equals 1234 & 0xff
    regs.read_u8 4
  expect_equals 1234
    regs.read_u16_le 4
  expect_equals 1234
    regs.read_i16_le 4

  regs.write_u16_le 5 65500
  expect_equals 65500 & 0xff
    regs.read_u8 5
  expect_equals 65500
    regs.read_u16_le 5
  expect_equals 65500 - 0x10000
    regs.read_i16_le 5

  regs.write_u16_be 5 65500
  expect_equals 65500 >> 8
    regs.read_u8 5
  expect_equals 65500
    regs.read_u16_be 5
  expect_equals 65500 - 0x10000
    regs.read_i16_be 5

  regs.write_i16_be 7 0x1234
  expect_equals 0x12
    regs.read_u8 7
  expect_equals 0x1234
    regs.read_u16_be 7
  expect_equals 0x1234
    regs.read_i16_be 7
  expect_equals 0x3412
    regs.read_u16_le 7
  expect_equals 0x3412
    regs.read_i16_le 7

  regs.write_u24_be 7 0x123456
  expect_equals 0x12
    regs.read_u8 7
  expect_equals 0x1234
    regs.read_u16_be 7
  expect_equals 0x1234
    regs.read_i16_be 7
  expect_equals 0x3412
    regs.read_u16_le 7
  expect_equals 0x3412
    regs.read_i16_le 7
  expect_equals 0x563412
    regs.read_u24_le 7
  expect_equals 0x563412
    regs.read_i24_le 7
  expect_equals 0x123456
    regs.read_u24_be 7
  expect_equals 0x123456
    regs.read_i24_be 7

  regs.write_i32_be 9 0x12345678
  expect_equals 0x12
    regs.read_u8 9
  expect_equals 0x1234
    regs.read_u16_be 9
  expect_equals 0x1234
    regs.read_i16_be 9
  expect_equals 0x3412
    regs.read_u16_le 9
  expect_equals 0x3412
    regs.read_i16_le 9
  expect_equals 0x78563412
    regs.read_u32_le 9
  expect_equals 0x78563412
    regs.read_i32_le 9

  regs.write_u32_le 9 0x12345678
  expect_equals 0x78
    regs.read_u8 9
  expect_equals 0x7856
    regs.read_u16_be 9
  expect_equals 0x7856
    regs.read_i16_be 9
  expect_equals 0x5678
    regs.read_u16_le 9
  expect_equals 0x5678
    regs.read_i16_le 9
  expect_equals 0x12345678
    regs.read_u32_le 9
  expect_equals 0x12345678
    regs.read_i32_le 9
