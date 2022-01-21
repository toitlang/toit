// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import encoding.hex as hex

import expect show *

main:
  test [0, 1, 2, 255]
  test []
  test [255]
  test
    ByteArray 16 * 1024

  expect_equals
    "ff"
    hex.encode
      ByteArray 1: 0xff

  expect_equals
    "INVALID_ARGUMENT"
    catch: hex.decode "hh"

  expect_equals
    "INVALID_ARGUMENT"
    catch: hex.decode "eee"

test array:
  ba := ByteArray array.size: array[it]
  expect
    equal
      ba
      hex.decode
        hex.encode
          ba

equal a b:
  if a.size != b.size: return false
  a.size.repeat: if a[it] != b[it]: return false
  return true
