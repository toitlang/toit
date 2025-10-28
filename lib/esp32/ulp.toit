// Copyright (C) 2025 Toit contributors.
// Use of this source code is governed by an MIT-style license that can be
// found in the lib/LICENSE file.

import io

/**
Library for interacting with the ESP32 ULP co-processor.
*/

/**
A ULP program binary.
*/
class Program:
  static MAGIC_ ::= 0x00706c75  // "ulp\0" in little-endian.
  static TEXT-OFFSET_ ::= 2
  bytes_/ByteArray
  load-address_/int

  constructor .bytes_ .load-address_=0:
    if bytes_.size % 4 != 0: throw "INVALID_ARGUMENT"
    if bytes_.size < 12: throw "INVALID_ARGUMENT"
    magic := io.LITTLE-ENDIAN.uint32 bytes_ 0
    if magic != MAGIC_: throw "INVALID_ARGUMENT"

  run:
    load_ bytes_
    run_ load-address_

load_ binary/ByteArray:
  #primitive.esp32.ulp_load

run_ entry-point/int:
  #primitive.esp32.ulp_run
