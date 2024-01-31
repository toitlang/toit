// Copyright (C) 2022 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import expect show *

main:
  test-clz
  test-ctz
  test-popcount
  test-parity
  test-vector-compare

test-clz:
  expect-equals 0
      (-1).count-leading-zeros
  expect-equals 64
      (0).count-leading-zeros
  expect-equals 55
      (0x100).count-leading-zeros
  expect-equals 23
      (0x100_0000_0000).count-leading-zeros
  expect-equals 0
      int.MIN.count-leading-zeros
  expect-equals 1
      int.MAX.count-leading-zeros

test-ctz:
  expect-equals 2
      (4).count-trailing-zeros
  expect-equals 0
      (1).count-trailing-zeros
  expect-equals 64
      (0).count-trailing-zeros
  expect-equals 0
      (-1).count-trailing-zeros
  expect-equals 1
      (-2).count-trailing-zeros
  expect-equals 16
      (0x10000).count-trailing-zeros
  expect-equals 16
      (0xac450000).count-trailing-zeros
  expect-equals 32
      (0x100000000).count-trailing-zeros
  expect-equals 32
      (0x8765432100000000).count-trailing-zeros
  expect-equals 63
      int.MIN.count-trailing-zeros
  expect-equals 0
      int.MAX.count-trailing-zeros

test-popcount:
  expect-equals 1
      (4).population-count
  expect-equals 1
      (1).population-count
  expect-equals 0
      (0).population-count
  expect-equals 64
      (-1).population-count
  expect-equals 63
      (-2).population-count
  expect-equals 1
      (0x10000).population-count
  expect-equals 7
      (0xac450000).population-count
  expect-equals 1
      (0x100000000).population-count
  expect-equals 13
      (0x8765432100000000).population-count
  expect-equals 1
      int.MIN.population-count
  expect-equals 63
      int.MAX.population-count

test-parity:
  expect
    0x34.has-odd-parity
  expect
    0x3c.has-even-parity

  expect-equals 1
    0x23.parity
  expect-equals 0
    0xff.parity
  expect-equals 0
    (-1).parity

test-vector-compare:
  expect-equals 0
    0.compare-equal-vector -1
  expect-equals 0b1111_1111
    0.compare-equal-vector 0
  expect-equals 0b1111_1110
    1.compare-equal-vector 2
  expect-equals 0b0101_0101
    (0x1200340056007800).compare-equal-vector 0
  expect-equals 0b0101_0101
    (0x1200340056007800).compare-equal-vector 0xff00ff00ff00ff00
  expect-equals 0b0101_0101
    (0x1242344256427842).compare-equal-vector 0xff42ff42ff42ff42
  expect-equals 0b1111_0000
    (0x1234_5678_0000_0000).compare-equal-vector 0x1234_5678_abab_cdcd
  expect-equals 0b1111_1111
    (-1).compare-equal-vector -1
