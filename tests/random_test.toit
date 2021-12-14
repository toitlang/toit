// Copyright (C) 2021 Toitware ApS. All rights reserved.

import binary show LITTLE_ENDIAN
import expect show *

main:
  ba := ByteArray 4
  LITTLE_ENDIAN.put_uint32 ba 0 16156990
  set_random_seed ba
  top := random
  // With this seed, the internal call to random will roll 268435455.
  r := random top
  expect_equals
    top - 1
    r
