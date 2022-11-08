// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import binary show LITTLE_ENDIAN
import expect show *

import crypto.crc show Crc
import crypto.crc16 show Crc16
import crypto.crc32 show Crc32

main:
  crc_polynomial_test

  crc_32_test

  crc_xmodem_test

crc_polynomial_test -> none:
  crc1 := Crc.little_endian 32 --polynomial=0xEDB88320
  crc2 := Crc.little_endian 32 --normal_polynomial=0x04C11DB7
  crc3 := Crc.little_endian 32 --powers=[26, 23, 22, 16, 12, 11, 10, 8, 7, 5, 4, 2, 1]
  crc4 := Crc.little_endian 32 --powers=[32, 26, 23, 22, 16, 12, 11, 10, 8, 7, 5, 4, 2, 1, 0]

  expect_equals crc1.polynomial crc2.polynomial
  expect_equals crc1.polynomial crc3.polynomial
  expect_equals crc1.polynomial crc4.polynomial
  expect
      identical crc1.table_ crc2.table_
  expect
      identical crc1.table_ crc3.table_
  expect
      identical crc1.table_ crc4.table_

  crc5 := Crc.big_endian 16 --polynomial=0x1021
  crc6 := Crc.big_endian 16 --powers=[12, 5, 0]
  crc7 := Crc.big_endian 16 --powers=[16, 12, 5, 0]
  expect_equals crc5.polynomial crc6.polynomial
  expect_equals crc5.polynomial crc7.polynomial
  expect
      identical crc5.table_ crc6.table_
  expect
      identical crc5.table_ crc7.table_

crc_32_test -> none:
  [true, false].do: | manual |
    [true, false].do: | use_string |
      crc := ?
      if manual:
        crc = Crc.little_endian 32 --polynomial=0xEDB88320 --initial_state=0xffff_ffff --xor_result=0xffff_ffff
      else:
        crc = Crc32
      if use_string:
        crc.add "Hello, World!"
      else:
        crc.add #['H', 'e', 'l', 'l', 'o', ',', ' ', 'W', 'o', 'r', 'l', 'd', '!']
      expect_equals 0xec4ac3d0 (LITTLE_ENDIAN.uint32 crc.get 0)

crc_xmodem_test -> none:
  crc := Crc16
  crc.add "Hello, World!"
  expect_equals #[0xd6, 0x4f] crc.get
