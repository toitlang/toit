// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *
import io show LITTLE-ENDIAN

import crypto.crc show Crc Crc16Xmodem Crc32

main:
  crc-polynomial-test

  crc-32-test

  crc-xmodem-test

crc-polynomial-test -> none:
  crc1 := Crc.little-endian 32 --polynomial=0xEDB88320
  crc2 := Crc.little-endian 32 --normal-polynomial=0x04C11DB7
  crc3 := Crc.little-endian 32 --powers=[26, 23, 22, 16, 12, 11, 10, 8, 7, 5, 4, 2, 1]
  crc4 := Crc.little-endian 32 --powers=[32, 26, 23, 22, 16, 12, 11, 10, 8, 7, 5, 4, 2, 1, 0]

  expect-equals crc1.polynomial crc2.polynomial
  expect-equals crc1.polynomial crc3.polynomial
  expect-equals crc1.polynomial crc4.polynomial
  expect
      identical crc1.table_ crc2.table_
  expect
      identical crc1.table_ crc3.table_
  expect
      identical crc1.table_ crc4.table_

  crc5 := Crc.big-endian 16 --polynomial=0x1021
  crc6 := Crc.big-endian 16 --powers=[12, 5, 0]
  crc7 := Crc.big-endian 16 --powers=[16, 12, 5, 0]
  expect-equals crc5.polynomial crc6.polynomial
  expect-equals crc5.polynomial crc7.polynomial
  expect
      identical crc5.table_ crc6.table_
  expect
      identical crc5.table_ crc7.table_

crc-32-test -> none:
  [true, false].do: | manual |
    [true, false].do: | use-string |
      crc := ?
      if manual:
        crc = Crc.little-endian 32 --polynomial=0xEDB88320 --initial-state=0xffff_ffff --xor-result=0xffff_ffff
      else:
        crc = Crc32
      if use-string:
        crc.add "Hello, World!"
      else:
        crc.add #['H', 'e', 'l', 'l', 'o', ',', ' ', 'W', 'o', 'r', 'l', 'd', '!']
      expect-equals 0xec4ac3d0 (LITTLE-ENDIAN.uint32 crc.get 0)

crc-xmodem-test -> none:
  crc := Crc16Xmodem
  crc.add "Hello, World!"
  expect-equals #[0x4f, 0xd6] crc.get
