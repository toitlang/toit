// Copyright (C) 2021 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import binary show LITTLE-ENDIAN BIG-ENDIAN
import expect show *
import serial.registers show Registers

class TestRegisters extends Registers:
  lo-regs := List 16: 0
  hi-regs := List 16: 0
  hi-word-regs := List 16: 0

  read-bytes reg/int count/int -> ByteArray:
    return read-bytes reg count: throw "wham!"

  read-bytes reg/int count/int [failure] -> ByteArray:
    if count == 1:
      return ByteArray 1: lo-regs[reg]
    if count == 2:
      ba := ByteArray 2
      ba[0] = lo-regs[reg]
      ba[1] = hi-regs[reg]
      return ba
    if count == 3:
      ba := ByteArray 3
      ba[0] = lo-regs[reg]
      ba[1] = hi-regs[reg]
      ba[2] = hi-word-regs[reg] & 0xff
      return ba
    if count == 4:
      ba := ByteArray 4
      ba[0] = lo-regs[reg]
      ba[1] = hi-regs[reg]
      ba[2] = hi-word-regs[reg] & 0xff
      ba[3] = hi-word-regs[reg] >> 8
      return ba
    return failure.call

  write-bytes reg/int data/ByteArray -> none:
    if data.size > 4: throw "OUT_OF_RANGE"
    if data.size > 0: lo-regs[reg] = data[0]
    if data.size > 1: hi-regs[reg] = data[1]
    if data.size > 2:
      value := hi-word-regs[reg]
      value &= 0xff00
      value |= data[2]
      hi-word-regs[reg] = value
    if data.size > 3:
      value := hi-word-regs[reg]
      value &= 0x00ff
      value |= data[3] << 8
      hi-word-regs[reg] = value

main:
  regs := TestRegisters
  expect-equals 0
    regs.read-u8 0
  expect-equals 0
    regs.read-u8 15

  expect-equals 0
    regs.read-i8 0
  expect-equals 0
    regs.read-i8 15

  regs.write-u8 12 42

  expect-equals 0
    regs.read-u8 0
  expect-equals 42
    regs.read-u8 12
  expect-equals 42
    regs.read-i8 12

  regs.write-u8 11 255
  expect-equals 255
    regs.read-u8 11
  expect-equals -1
    regs.read-i8 11

  regs.write-i16-le 4 1234
  expect-equals 1234 & 0xff
    regs.read-u8 4
  expect-equals 1234
    regs.read-u16-le 4
  expect-equals 1234
    regs.read-i16-le 4

  regs.write-u16-le 5 65500
  expect-equals 65500 & 0xff
    regs.read-u8 5
  expect-equals 65500
    regs.read-u16-le 5
  expect-equals 65500 - 0x10000
    regs.read-i16-le 5

  regs.write-u16-be 5 65500
  expect-equals 65500 >> 8
    regs.read-u8 5
  expect-equals 65500
    regs.read-u16-be 5
  expect-equals 65500 - 0x10000
    regs.read-i16-be 5

  regs.write-i16-be 7 0x1234
  expect-equals 0x12
    regs.read-u8 7
  expect-equals 0x1234
    regs.read-u16-be 7
  expect-equals 0x1234
    regs.read-i16-be 7
  expect-equals 0x3412
    regs.read-u16-le 7
  expect-equals 0x3412
    regs.read-i16-le 7

  regs.write-u24-be 7 0x123456
  expect-equals 0x12
    regs.read-u8 7
  expect-equals 0x1234
    regs.read-u16-be 7
  expect-equals 0x1234
    regs.read-i16-be 7
  expect-equals 0x3412
    regs.read-u16-le 7
  expect-equals 0x3412
    regs.read-i16-le 7
  expect-equals 0x563412
    regs.read-u24-le 7
  expect-equals 0x563412
    regs.read-i24-le 7
  expect-equals 0x123456
    regs.read-u24-be 7
  expect-equals 0x123456
    regs.read-i24-be 7

  regs.write-i32-be 9 0x12345678
  expect-equals 0x12
    regs.read-u8 9
  expect-equals 0x1234
    regs.read-u16-be 9
  expect-equals 0x1234
    regs.read-i16-be 9
  expect-equals 0x3412
    regs.read-u16-le 9
  expect-equals 0x3412
    regs.read-i16-le 9
  expect-equals 0x78563412
    regs.read-u32-le 9
  expect-equals 0x78563412
    regs.read-i32-le 9

  regs.write-u32-le 9 0x12345678
  expect-equals 0x78
    regs.read-u8 9
  expect-equals 0x7856
    regs.read-u16-be 9
  expect-equals 0x7856
    regs.read-i16-be 9
  expect-equals 0x5678
    regs.read-u16-le 9
  expect-equals 0x5678
    regs.read-i16-le 9
  expect-equals 0x12345678
    regs.read-u32-le 9
  expect-equals 0x12345678
    regs.read-i32-le 9
