// Copyright (C) 2023 Toitware ApS.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the tests/LICENSE file.

import zlib

// Prior to the commit that added this test, the pure Toit decoder
// would fail with an array bounds error when decoding this stream.
// The issue was that the last entry in the HLIT and HDIST tables
// was written with a repeat code, and we didn't check that the
// tables were full before reading the next symbol.

main:
  decoder := zlib.BufferingInflater

  decoder.out.write ZLIB_STREAM

  while read := decoder.in.read:
    null

ZLIB_STREAM ::= #[
    0x78, 0x9c, 0xed, 0xdd, 0x6b, 0xac, 0x65,
    0xf5, 0x79, 0xdf, 0xf1, 0x87, 0x01, 0x86, 0x18, 0x54, 0xc0, 0x38, 0xad,
    0x03, 0xf8, 0x92, 0x46, 0x55, 0x54, 0x6c, 0xd7, 0x06, 0x9c, 0x38, 0x69,
    0xe4, 0x4a, 0x6d, 0xdc, 0xe0, 0x18, 0x3b, 0x52, 0x1b, 0x8a, 0x89, 0xd5,
    0x0b, 0xc4, 0xae, 0x68, 0x71, 0x12, 0xd7, 0xf1, 0x95, 0x72, 0x33, 0x72,
    0xa4, 0xbe, 0xab, 0x2a, 0x27, 0x50, 0xe3, 0xa6, 0x6f, 0xfa, 0x22, 0x89,
    0x5b, 0x4b, 0xa9, 0x14, 0x57, 0x55, 0x9b, 0xd6, 0x96, 0x55, 0xa5, 0x97,
    0xd4, 0x7d, 0x91, 0x92, 0xc4, 0xd1, 0x04, 0x86, 0x19, 0x06, 0x43, 0x20,
    0x36, 0x31, 0x36, 0x36, 0x13, 0x0f, 0x1c, 0xef, 0xfc, 0x61, 0x9b, 0x93,
    0x3d, 0x7b, 0x9f, 0xb3, 0x66, 0x38, 0xb3, 0xfe, 0x97, 0x67, 0xfc, 0xf9,
    0xea, 0x2b, 0x0b, 0xcf, 0x9c, 0xb3, 0xf6, 0xfa, 0x3d, 0x23, 0x3d, 0xeb,
    0xa7, 0xb5, 0x6f, 0x11, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xd2, 0xb0, 0x00, 0x00,
    0x4c, 0x12, 0x95, 0x39, 0x7c, 0xf8, 0x4e, 0x92, 0xe4, 0x84, 0x91, 0x9d,
    0x72, 0x2d, 0xe9, 0x3e, 0xc4, 0xd3, 0xde, 0xe5, 0x35, 0xbb, 0xfb, 0x69,
    0x98, 0x33, 0xcd, 0x79, 0x6f, 0x79, 0xa3, 0x32, 0xdd, 0x33, 0x92, 0xe4,
    0, 0, 0, 0, 0,
    // Symbol 256 (end of zlib part), encoding 111111100110 len=12
    // Bit-reverse it.
    0b0111_1111, 0b0000_0110,
    // Checksum.
    0xc3, 0xec, 0x98, 0x3c]
