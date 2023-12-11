// Copyright (C) 2021 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import binary show LITTLE-ENDIAN
import expect show *
import .io-data

main:
  ba := ByteArray 4
  LITTLE-ENDIAN.put-uint32 ba 0 16156990
  set-random-seed ba
  top := random
  // With this seed, the internal call to random will roll 268435455.
  r := random top
  expect-equals
    top - 1
    r

  set-random-seed (FakeData ba)
  top = random
  r = random top
  expect-equals
    top - 1
    r
