// Copyright (C) 2019 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import encoding.hex as hex

import expect show *

import .io-utils

main:
  test [0, 1, 2, 255]
  test []
  test [255]
  test
    ByteArray 16 * 1024

  expect-equals
    "ff"
    hex.encode
      ByteArray 1 --initial=0xff

  expect-equals
    "ff"
    hex.encode (FakeData (ByteArray 1 --initial=0xff))

  expect-equals
    "INTEGER_PARSING_ERROR"
    catch: hex.decode "hh"

  expect-equals
    #[0x0e]
    hex.decode "e"

  expect-equals
    #[0x0e, 0xee]
    hex.decode "eee"

  expect-equals
    #[0x0d, 0xef]
    hex.decode "def"

  expect-equals
    #[0x0c, 0x0f, 0xfe]
    hex.decode "c0ffe"

  expect-equals
    #[0, 0, 0x0e]
    hex.decode "0000e"

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
